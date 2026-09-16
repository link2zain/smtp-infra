#!/bin/bash
# Run as: sudo bash setup.sh
# Idempotent: safe to re-run — won't reinstall Docker if present, won't regenerate secrets if a
# .env already exists, won't duplicate firewall rules.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this with sudo: sudo bash setup.sh" >&2
  exit 1
fi

TARGET_DIR="/opt/sengrid"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Installing Docker (skipped if already present)"
if ! command -v docker &>/dev/null; then
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
else
  echo "    docker already installed: $(docker --version)"
fi

echo "==> Setting up $TARGET_DIR"
mkdir -p "$TARGET_DIR"
cp "$SCRIPT_DIR/docker-compose.yml" "$TARGET_DIR/"
cp "$SCRIPT_DIR/init-replication.sh" "$TARGET_DIR/"
cp "$SCRIPT_DIR/redis.conf.template" "$TARGET_DIR/"
cp "$SCRIPT_DIR/redis-entrypoint.sh" "$TARGET_DIR/"
chmod +x "$TARGET_DIR/redis-entrypoint.sh" "$TARGET_DIR/init-replication.sh"

ENV_FILE="$TARGET_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  echo "==> $ENV_FILE already exists — leaving it alone (delete it first if you want fresh secrets)"
else
  echo "==> Generating secrets into $ENV_FILE"
  {
    echo "POSTGRES_DB=sengrid"
    echo "POSTGRES_USER=sengrid"
    echo "POSTGRES_PASSWORD=$(openssl rand -base64 24)"
    # Fixed (not randomly generated here) because smtp-db-replica's setup script needs the exact
    # same value and there's no passwordless way to read this file back across VMs to sync it.
    echo "REPLICATION_PASSWORD=REPLACE_WITH_YOUR_OWN_GENERATED_SECRET"
    echo "REDIS_PASSWORD=$(openssl rand -base64 24)"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
fi

echo "==> Firewall: restricting 5432/6379 to the 10.10.1.0/24 subnet"
if command -v ufw &>/dev/null; then
  # Always allow SSH first -- enabling ufw with no explicit allow rule for 22 locks out
  # the very session managing the box, since ufw defaults to deny-incoming once enabled.
  ufw allow 22/tcp comment 'SSH'
  ufw allow from 10.10.1.0/24 to any port 5432 proto tcp comment 'postgres - internal only' || true
  ufw allow from 10.10.1.0/24 to any port 6379 proto tcp comment 'redis - internal only' || true
  ufw --force enable || true
else
  echo "    ufw not found — install/configure a firewall manually to restrict 5432/6379 to 10.10.1.0/24"
fi

echo "==> Starting Postgres + Redis"
cd "$TARGET_DIR"
docker compose --env-file .env up -d

echo ""
echo "Done. Check status with: docker compose -f $TARGET_DIR/docker-compose.yml ps"
echo "Secrets are in $ENV_FILE (root-only, chmod 600) — needed on the replica and by the app."
