#!/bin/bash
# Run on the DB Primary VM as: sudo bash setup.sh
# Needs secrets POSTGRES_PASSWORD, REPLICATION_PASSWORD, REDIS_PASSWORD (see ../README.md).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

require_root
load_secrets
require_secret POSTGRES_PASSWORD REPLICATION_PASSWORD REDIS_PASSWORD
install_docker

echo "==> Setting up $TARGET_DIR"
mkdir -p "$TARGET_DIR"
cp "$SCRIPT_DIR/docker-compose.yml" "$SCRIPT_DIR/init-replication.sh" \
   "$SCRIPT_DIR/redis.conf.template" "$SCRIPT_DIR/redis-entrypoint.sh" "$TARGET_DIR/"
chmod +x "$TARGET_DIR/redis-entrypoint.sh" "$TARGET_DIR/init-replication.sh"

ENV_FILE="$TARGET_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  echo "==> $ENV_FILE already exists — leaving it alone (delete it first to re-apply secrets)"
else
  echo "==> Writing $ENV_FILE"
  {
    echo "POSTGRES_DB=sengrid"
    echo "POSTGRES_USER=sengrid"
    echo "POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
    echo "REPLICATION_PASSWORD=$REPLICATION_PASSWORD"
    echo "REDIS_PASSWORD=$REDIS_PASSWORD"
    echo "REPLICA_IP=$DB_SECONDARY_IP"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
fi

echo "==> Firewall: Postgres from the website + secondary only, Redis from the website only"
ufw_begin
allow_from 5432 'postgres - website + secondary only' "$WEBSITE_IP" "$DB_SECONDARY_IP"
allow_from 6379 'redis - website only' "$WEBSITE_IP"
ufw_commit

echo "==> Starting Postgres + Redis"
cd "$TARGET_DIR"
docker compose --env-file .env up -d

echo "Done. Check: docker compose -f $TARGET_DIR/docker-compose.yml ps"
