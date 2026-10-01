#!/bin/bash
# Run on the Website+Proxy VM as: sudo bash setup.sh
# Needs, next to this script's tier dir: app.jar (built smtp-backend) and frontend-dist/ (built
# smtp-frontend `dist`) -- build artifacts, not in git. Secrets needed: POSTGRES_PASSWORD,
# RABBITMQ_DEFAULT_PASS, SENGRID_JWT_SECRET (see ../README.md).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

require_root
load_secrets
require_secret POSTGRES_PASSWORD RABBITMQ_DEFAULT_PASS SENGRID_JWT_SECRET
[ -f "$SCRIPT_DIR/app.jar" ] && [ -d "$SCRIPT_DIR/frontend-dist" ] \
  || fatal "app.jar and frontend-dist/ must sit next to this script (mvn package / npm run build)"

echo "==> Installing Java 17 + nginx"
apt-get update -qq
apt-get install -y -qq openjdk-17-jre-headless nginx

echo "==> Creating the dedicated 'sengrid' system user (no login, no home dir)"
id sengrid &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin sengrid

echo "==> Deploying the backend jar + frontend build"
mkdir -p "$TARGET_DIR/backend" "$TARGET_DIR/frontend"
cp "$SCRIPT_DIR/app.jar" "$TARGET_DIR/backend/app.jar"
rm -rf "$TARGET_DIR/frontend/dist"
cp -r "$SCRIPT_DIR/frontend-dist" "$TARGET_DIR/frontend/dist"
chown -R sengrid:sengrid "$TARGET_DIR/backend"
chown -R www-data:www-data "$TARGET_DIR/frontend"

ENV_FILE="$TARGET_DIR/backend.env"
if [ -f "$ENV_FILE" ]; then
  echo "==> $ENV_FILE already exists — leaving it alone (delete it first to re-apply secrets)"
else
  echo "==> Writing $ENV_FILE"
  {
    echo "SPRING_PROFILES_ACTIVE=docker"
    echo "SERVER_PORT=8080"
    echo "DB_URL=jdbc:postgresql://$DB_PRIMARY_IP:5432/sengrid"
    echo "DB_USER=sengrid"
    echo "DB_PASSWORD=$POSTGRES_PASSWORD"
    echo "SENGRID_JWT_SECRET=$SENGRID_JWT_SECRET"
    # No public DNS/TLS yet -- the VM's own address is the only real origin. Switch both of these
    # to https://$DOMAIN at domain cutover (reset links and tracking URLs are built from this).
    echo "SENGRID_CORS_ALLOWED_ORIGINS=http://$WEBSITE_IP"
    echo "SENGRID_TRACKING_BASE_URL=http://$WEBSITE_IP"
    echo "SENGRID_MAIL_SYSTEM_FROM=noreply@$DOMAIN"
    echo "SPRING_RABBITMQ_ADDRESSES=$MAIL1_IP:5672,$MAIL2_IP:5672,$MAIL3_IP:5672"
    echo "SPRING_RABBITMQ_USERNAME=sengrid"
    echo "SPRING_RABBITMQ_PASSWORD=$RABBITMQ_DEFAULT_PASS"
    # Mail 1 for now (single default listener per mail node, no per-pool IPs yet).
    echo "SPRING_MAIL_HOST=$MAIL1_IP"
    echo "SPRING_MAIL_PORT=25"
    echo "SENGRID_MAIL_PROVIDER=self-hosted-smtp"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  chown sengrid:sengrid "$ENV_FILE"
fi

echo "==> Installing the systemd unit"
cp "$SCRIPT_DIR/sengrid-backend.service" /etc/systemd/system/sengrid-backend.service
systemctl daemon-reload
systemctl enable sengrid-backend
systemctl restart sengrid-backend

echo "==> Installing the nginx site (frontend + /api + /actuator reverse proxy)"
cp "$SCRIPT_DIR/nginx.conf" /etc/nginx/sites-available/sengrid
ln -sf /etc/nginx/sites-available/sengrid /etc/nginx/sites-enabled/sengrid
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx || systemctl restart nginx
systemctl enable nginx

echo "==> Firewall: port 80 open, backend port 8080 only to the monitoring VM"
ufw_begin
ufw allow 80/tcp comment 'website + api' >/dev/null
allow_from 8080 'backend actuator - monitoring only' "$MONITOR_IP"
ufw_commit

echo "Done. Backend logs: journalctl -u sengrid-backend -f"
