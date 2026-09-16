#!/bin/bash
# Run as: sudo bash setup.sh
# Expects, alongside this script: app.jar (built smtp-backend jar) and frontend-dist/ (built
# smtp-frontend `dist` output) -- both are build artifacts, not committed to git, so they must be
# copied in separately before running this.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this with sudo: sudo bash setup.sh" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="/opt/sengrid"

if [ ! -f "$SCRIPT_DIR/app.jar" ] || [ ! -d "$SCRIPT_DIR/frontend-dist" ]; then
  echo "FATAL: app.jar and/or frontend-dist/ missing next to this script -- build and copy them" >&2
  echo "       here first (mvn package for the jar, npm run build -> dist/ for the frontend)." >&2
  exit 1
fi

# These must match the exact values already live in the DB and mail tiers -- there's no
# passwordless way to read another VM's root-owned .env back to sync them automatically.
DB_PASSWORD_VALUE="REPLACE_WITH_YOUR_OWN_GENERATED_SECRET"
RABBITMQ_PASSWORD_VALUE="REPLACE_WITH_YOUR_OWN_GENERATED_SECRET"
for name_value in "DB_PASSWORD_VALUE:$DB_PASSWORD_VALUE" "RABBITMQ_PASSWORD_VALUE:$RABBITMQ_PASSWORD_VALUE"; do
  name="${name_value%%:*}"; value="${name_value#*:}"
  if [ "$value" = "REPLACE_WITH_YOUR_OWN_GENERATED_SECRET" ]; then
    echo "FATAL: edit this script and replace $name with the real value already deployed on" >&2
    echo "       smtp-db-primary (POSTGRES_PASSWORD) / smtp-mail-1 (RABBITMQ_DEFAULT_PASS)." >&2
    exit 1
  fi
done

echo "==> Installing Java 17 + nginx (skipped if already present)"
apt-get update -qq
apt-get install -y -qq openjdk-17-jre-headless nginx

echo "==> Creating the dedicated 'sengrid' system user (no login, no home dir)"
if ! id sengrid &>/dev/null; then
  useradd --system --no-create-home --shell /usr/sbin/nologin sengrid
fi

echo "==> Deploying the backend jar + frontend build"
mkdir -p "$TARGET_DIR/backend" "$TARGET_DIR/frontend"
cp "$SCRIPT_DIR/app.jar" "$TARGET_DIR/backend/app.jar"
rm -rf "$TARGET_DIR/frontend/dist"
cp -r "$SCRIPT_DIR/frontend-dist" "$TARGET_DIR/frontend/dist"
chown -R sengrid:sengrid "$TARGET_DIR/backend"
chown -R www-data:www-data "$TARGET_DIR/frontend"

ENV_FILE="$TARGET_DIR/backend.env"
if [ -f "$ENV_FILE" ]; then
  echo "==> $ENV_FILE already exists — leaving it alone (delete it first if you want fresh secrets)"
else
  echo "==> Writing $ENV_FILE"
  {
    echo "SPRING_PROFILES_ACTIVE=docker"
    echo "SERVER_PORT=8080"
    echo "DB_URL=jdbc:postgresql://10.10.1.5:5432/sengrid"
    echo "DB_USER=sengrid"
    echo "DB_PASSWORD=$DB_PASSWORD_VALUE"
    # No cross-host consistency needed for this one -- generated fresh here, every run.
    echo "SENGRID_JWT_SECRET=$(openssl rand -base64 48 | tr -d '\n')"
    # No public DNS/IP for this environment yet -- private IP is the only real origin that
    # exists right now. Update once a real domain/public IP is in place.
    echo "SENGRID_CORS_ALLOWED_ORIGINS=http://10.10.1.4"
    echo "SPRING_RABBITMQ_ADDRESSES=10.10.1.7:5672,10.10.1.8:5672,10.10.1.9:5672"
    echo "SPRING_RABBITMQ_USERNAME=sengrid"
    echo "SPRING_RABBITMQ_PASSWORD=$RABBITMQ_PASSWORD_VALUE"
    # smtp-mail-1 for now (single default listener, no per-pool IPs yet -- see the mail tier's
    # own setup.sh notes). Revisit once real IP pools exist.
    echo "SPRING_MAIL_HOST=10.10.1.7"
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

echo "==> Firewall: SSH always allowed, port 80 public, port 8080 restricted to the subnet"
if command -v ufw &>/dev/null; then
  ufw allow 22/tcp comment 'SSH'
  ufw allow 80/tcp comment 'frontend + api (public)'
  ufw allow from 10.10.1.0/24 to any port 8080 proto tcp comment 'backend actuator - internal only'
  ufw --force enable
else
  echo "    ufw not found — configure a firewall manually"
fi

echo ""
echo "Done. Backend logs: journalctl -u sengrid-backend -f"
echo "First boot runs Flyway migrations against the fresh DB -- check the log for completion"
echo "before hitting the API."
