#!/bin/bash
# Run as: sudo bash setup.sh
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
cp "$SCRIPT_DIR/prometheus.yml" "$TARGET_DIR/"
cp "$SCRIPT_DIR/grafana-datasource.yml" "$TARGET_DIR/"

ENV_FILE="$TARGET_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  echo "==> $ENV_FILE already exists — leaving it alone"
else
  echo "==> Writing $ENV_FILE"
  # No cross-host consistency needed -- this is the only Grafana instance -- so a freshly
  # generated secret each run is simpler and safer than the fixed-value pattern used where
  # multiple VMs need to agree on the same secret.
  {
    echo "GRAFANA_ADMIN_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
fi

echo "==> Firewall: SSH always allowed, Prometheus + Grafana restricted to the subnet"
if command -v ufw &>/dev/null; then
  ufw allow 22/tcp comment 'SSH'
  ufw allow from 10.10.1.0/24 to any port 9090 proto tcp comment 'prometheus ui - internal only'
  ufw allow from 10.10.1.0/24 to any port 3000 proto tcp comment 'grafana ui - internal only'
  ufw --force enable
else
  echo "    ufw not found — configure a firewall manually to restrict 9090/3000 to 10.10.1.0/24"
fi

echo "==> Starting Prometheus + Grafana"
cd "$TARGET_DIR"
docker compose --env-file .env up -d

echo ""
echo "Done. Grafana: http://10.10.1.12:3000 (admin / see $ENV_FILE for the password)"
echo "Prometheus:    http://10.10.1.12:9090"
echo ""
echo "IMPORTANT: RabbitMQ's Prometheus port (15692) isn't open yet on the 3 mail nodes' firewalls"
echo "-- that was added to their setup.sh after they were first deployed. Run on each of"
echo "smtp-mail-1/2/3: sudo ufw allow from 10.10.1.0/24 to any port 15692 proto tcp"
