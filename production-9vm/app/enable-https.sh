#!/bin/bash
# Run on the website VM as: sudo bash enable-https.sh
# Gets a Let's Encrypt certificate for the domain using a DNS challenge through Cloudflare (port 80
# isn't reachable from the internet here, so the usual HTTP challenge can't work), switches nginx
# to serve HTTPS, opens 443, and points the backend's public URLs at https.
#
# Needs CLOUDFLARE_API_TOKEN (permission Zone > DNS > Edit, limited to this one zone) in
# /dev/shm/postafly-secrets.env. It is copied to /etc/letsencrypt/cloudflare.ini (root only,
# mode 600) so certbot can renew by itself; it is never stored in git.
# Optional: DOMAIN (default postafly.com.pk), LE_EMAIL (expiry notices from Let's Encrypt).
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo" >&2; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAIN="${DOMAIN:-postafly.com.pk}"
SECRETS="${SECRETS_FILE:-/dev/shm/postafly-secrets.env}"
[ -f "$SECRETS" ] || { echo "FATAL: $SECRETS not found" >&2; exit 1; }
set -a; . "$SECRETS"; set +a
[ -n "${CLOUDFLARE_API_TOKEN:-}" ] || { echo "FATAL: CLOUDFLARE_API_TOKEN missing" >&2; exit 1; }

echo "==> Installing certbot + the Cloudflare DNS plugin"
apt-get update -qq
apt-get install -y -qq certbot python3-certbot-dns-cloudflare

echo "==> Storing the Cloudflare token for renewals (root only)"
install -d -m 700 /etc/letsencrypt
( umask 077; printf 'dns_cloudflare_api_token = %s\n' "$CLOUDFLARE_API_TOKEN" > /etc/letsencrypt/cloudflare.ini )
chmod 600 /etc/letsencrypt/cloudflare.ini

echo "==> Requesting the certificate for $DOMAIN and www.$DOMAIN"
if [ -n "${LE_EMAIL:-}" ]; then EMAIL_ARGS=(-m "$LE_EMAIL"); else EMAIL_ARGS=(--register-unsafely-without-email); fi
certbot certonly --dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
  --dns-cloudflare-propagation-seconds 30 \
  -d "$DOMAIN" -d "www.$DOMAIN" \
  --non-interactive --agree-tos "${EMAIL_ARGS[@]}" \
  --deploy-hook "systemctl reload nginx"

echo "==> Switching nginx to HTTPS"
cp /etc/nginx/sites-available/sengrid /etc/nginx/sites-available/sengrid.before-https
sed "s/__DOMAIN__/$DOMAIN/g" "$SCRIPT_DIR/nginx-https.conf.template" > /etc/nginx/sites-available/sengrid
nginx -t
systemctl reload nginx

echo "==> Firewall: allow 443"
ufw allow 443/tcp comment 'https (public)' >/dev/null

echo "==> Pointing the backend's public URLs at https://$DOMAIN"
ENV_FILE=/opt/sengrid/backend.env
setvar() { if grep -q "^$1=" "$ENV_FILE"; then sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"; else echo "$1=$2" >> "$ENV_FILE"; fi; }
setvar SENGRID_CORS_ALLOWED_ORIGINS "https://$DOMAIN,https://www.$DOMAIN"
setvar SENGRID_TRACKING_BASE_URL "https://$DOMAIN"
systemctl restart sengrid-backend

echo "==> Testing automatic renewal (dry run against Let's Encrypt staging)"
certbot renew --dry-run

echo "Done. Certificate details: certbot certificates"
