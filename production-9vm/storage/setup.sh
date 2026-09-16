#!/bin/bash
# Run as: sudo bash setup.sh
# Identical script, run on BOTH smtp-storage-1 and smtp-storage-2 — MinIO distributed mode expects
# every node started with the exact same 4-endpoint list; it figures out which ones are itself.
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

echo "==> Creating dedicated MinIO data directories on the two real physical disks"
# Subdirectories, not the mount roots themselves — /var and /var/lib are system mount points that
# already hold real OS content (logs, package cache, docker's own data-root under /var/lib/docker
# once installed above); MinIO gets its own clean subdirectory on each disk instead of the whole
# filesystem, so it can't collide with what the OS is already keeping there.
mkdir -p /var/minio-data/disk1 /var/lib/minio-data/disk2

echo "==> Setting up $TARGET_DIR"
mkdir -p "$TARGET_DIR"
cp "$SCRIPT_DIR/docker-compose.yml" "$TARGET_DIR/"

MINIO_ROOT_PASSWORD_VALUE="REPLACE_WITH_YOUR_OWN_GENERATED_SECRET"
if [ "$MINIO_ROOT_PASSWORD_VALUE" = "REPLACE_WITH_YOUR_OWN_GENERATED_SECRET" ]; then
  echo "FATAL: edit this script and replace MINIO_ROOT_PASSWORD_VALUE with a real generated secret" >&2
  echo "       (same value on both storage nodes) before running it against a real VM." >&2
  exit 1
fi

ENV_FILE="$TARGET_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  echo "==> $ENV_FILE already exists — leaving it alone"
else
  echo "==> Writing $ENV_FILE"
  {
    echo "MINIO_ROOT_USER=sengrid-admin"
    # Fixed (not randomly generated) — every node in the cluster must use the identical value,
    # and there's no passwordless way to read one node's secret back to sync into another.
    echo "MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD_VALUE"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
fi

echo "==> Firewall: SSH always allowed, then 9000 (S3 API) + 9001 (console) restricted to the subnet"
if command -v ufw &>/dev/null; then
  ufw allow 22/tcp comment 'SSH'
  ufw allow from 10.10.1.0/24 to any port 9000 proto tcp comment 'minio S3 api - internal only'
  ufw allow from 10.10.1.0/24 to any port 9001 proto tcp comment 'minio console - internal only'
  ufw --force enable
else
  echo "    ufw not found — configure a firewall manually to restrict 9000/9001 to 10.10.1.0/24"
fi

echo "==> Starting MinIO"
cd "$TARGET_DIR"
docker compose --env-file .env up -d

echo ""
echo "Done. This node won't fully form the cluster until the SAME script has run on the other"
echo "storage node too — MinIO waits for all 4 configured endpoints to be reachable before"
echo "serving. Check progress with: docker compose -f $TARGET_DIR/docker-compose.yml logs -f"
