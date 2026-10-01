#!/bin/bash
# Run on the DB Secondary VM as: sudo bash setup.sh   -- AFTER db-primary/setup.sh has finished.
# Needs secret REPLICATION_PASSWORD (see ../README.md).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

require_root
load_secrets
require_secret REPLICATION_PASSWORD
install_docker

echo "==> Checking the primary is reachable on 5432 before proceeding"
timeout 5 bash -c "cat < /dev/null > /dev/tcp/$DB_PRIMARY_IP/5432" 2>/dev/null \
  || fatal "cannot reach $DB_PRIMARY_IP:5432 -- run db-primary/setup.sh first"

echo "==> Setting up $TARGET_DIR"
mkdir -p "$TARGET_DIR"
cp "$SCRIPT_DIR/docker-compose.yml" "$SCRIPT_DIR/replica-entrypoint.sh" "$TARGET_DIR/"
chmod +x "$TARGET_DIR/replica-entrypoint.sh"

ENV_FILE="$TARGET_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  echo "==> $ENV_FILE already exists — leaving it alone"
else
  echo "==> Writing $ENV_FILE"
  {
    echo "PRIMARY_HOST=$DB_PRIMARY_IP"
    echo "REPLICATION_PASSWORD=$REPLICATION_PASSWORD"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
fi

echo "==> Firewall: Postgres from the website + primary only"
ufw_begin
allow_from 5432 'postgres replica - website + primary only' "$WEBSITE_IP" "$DB_PRIMARY_IP"
ufw_commit

echo "==> Starting the replica (first boot clones the primary — can take a few minutes)"
cd "$TARGET_DIR"
docker compose --env-file .env up -d

echo "Done. On the PRIMARY, confirm with: select * from pg_stat_replication;"
