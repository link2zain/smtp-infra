#!/bin/bash
# Run on the Monitoring VM as: sudo bash setup.sh
# Needs secret GRAFANA_ADMIN_PASSWORD (see ../README.md).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

require_root
load_secrets
require_secret GRAFANA_ADMIN_PASSWORD
install_docker

echo "==> Setting up $TARGET_DIR"
mkdir -p "$TARGET_DIR"
cp "$SCRIPT_DIR/docker-compose.yml" "$SCRIPT_DIR/prometheus.yml" "$SCRIPT_DIR/grafana-datasource.yml" "$TARGET_DIR/"

ENV_FILE="$TARGET_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  echo "==> $ENV_FILE already exists — leaving it alone"
else
  echo "==> Writing $ENV_FILE"
  echo "GRAFANA_ADMIN_PASSWORD=$GRAFANA_ADMIN_PASSWORD" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
fi

echo "==> Firewall: Prometheus + Grafana UIs from the admin network only"
ufw_begin
allow_from 9090 'prometheus ui - admin network' "$ADMIN_NET"
allow_from 3000 'grafana ui - admin network' "$ADMIN_NET"
ufw_commit

echo "==> Starting Prometheus + Grafana"
cd "$TARGET_DIR"
docker compose --env-file .env up -d

echo "Done. Grafana: http://$MONITOR_IP:3000 (admin; password is in $ENV_FILE)   Prometheus: http://$MONITOR_IP:9090"
