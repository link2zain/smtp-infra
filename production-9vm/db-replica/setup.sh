#!/bin/bash
# Run as: sudo bash setup.sh
# Must be run AFTER smtp-db-primary's setup.sh has already started Postgres — this connects
# to it immediately on first boot to clone via pg_basebackup.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this with sudo: sudo bash setup.sh" >&2
  exit 1
fi

TARGET_DIR="/opt/sengrid"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRIMARY_HOST="10.10.1.5"

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

echo "==> Checking the primary is reachable on 5432 before proceeding"
if ! timeout 5 bash -c "cat < /dev/null > /dev/tcp/$PRIMARY_HOST/5432" 2>/dev/null; then
  echo "FATAL: cannot reach $PRIMARY_HOST:5432 — run smtp-db-primary's setup.sh first." >&2
  exit 1
fi

echo "==> Setting up $TARGET_DIR"
mkdir -p "$TARGET_DIR"
cp "$SCRIPT_DIR/docker-compose.yml" "$TARGET_DIR/"
cp "$SCRIPT_DIR/replica-entrypoint.sh" "$TARGET_DIR/"
chmod +x "$TARGET_DIR/replica-entrypoint.sh"

REPLICATION_PASSWORD_VALUE="REPLACE_WITH_YOUR_OWN_GENERATED_SECRET"
if [ "$REPLICATION_PASSWORD_VALUE" = "REPLACE_WITH_YOUR_OWN_GENERATED_SECRET" ]; then
  echo "FATAL: edit this script and replace REPLICATION_PASSWORD_VALUE with the exact same real" >&2
  echo "       secret already generated into smtp-db-primary's .env before running this." >&2
  exit 1
fi

ENV_FILE="$TARGET_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  echo "==> $ENV_FILE already exists — leaving it alone"
else
  echo "==> Writing $ENV_FILE"
  {
    echo "PRIMARY_HOST=$PRIMARY_HOST"
    # Must match smtp-db-primary's REPLICATION_PASSWORD exactly — both are fixed to the same
    # generated value in their respective setup.sh for this reason.
    echo "REPLICATION_PASSWORD=$REPLICATION_PASSWORD_VALUE"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
fi

echo "==> Firewall: restricting 5432 to the 10.10.1.0/24 subnet"
if command -v ufw &>/dev/null; then
  # Always allow SSH first -- enabling ufw with no explicit allow rule for 22 locks out
  # the very session managing the box, since ufw defaults to deny-incoming once enabled.
  ufw allow 22/tcp comment 'SSH'
  ufw allow from 10.10.1.0/24 to any port 5432 proto tcp comment 'postgres replica - internal only' || true
  ufw --force enable || true
else
  echo "    ufw not found — configure a firewall manually to restrict 5432 to 10.10.1.0/24"
fi

echo "==> Starting the replica (first boot clones the primary — can take a few minutes)"
cd "$TARGET_DIR"
docker compose --env-file .env up -d

echo ""
echo "Done. Watch the clone/replication progress with:"
echo "  docker compose -f $TARGET_DIR/docker-compose.yml logs -f"
echo "Once caught up, confirm on the PRIMARY with:"
echo "  docker exec -it \$(docker ps -qf name=postgres) psql -U sengrid -c 'select * from pg_stat_replication;'"
