#!/bin/bash
# Run on the website VM (smtp-app) as: sudo bash enable-images.sh /path/to/postafly-images-app.env
#
# Turns on the picture library's public side and wires the backend to the storage servers:
#   1. a Let's Encrypt certificate for img.postafly.com.pk (DNS challenge through Cloudflare, like the main site)
#   2. nginx: public picture host (conf.d/postafly-img.conf) from nginx-img.conf.template, and a 11 MB
#      upload limit for /api/v1/images (nginx's default of 1 MB would refuse every phone photo)
#   3. the Cloudflare DNS record for img (DNS only to start with; see the note at the end)
#   4. the backend's picture settings in /opt/sengrid/backend.env (the backend is NOT restarted here)
#
# The argument is the credentials file made by storage/images-bucket.sh on smtp-storage-1
# (SENGRID_IMAGES_ACCESS_KEY / SENGRID_IMAGES_SECRET_KEY). Secrets are never printed.
# Optional: DOMAIN (default postafly.com.pk), IMG_PROXIED=true to put the DNS record behind Cloudflare.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo" >&2; exit 1; }
CRED="${1:-}"
[ -f "$CRED" ] || { echo "usage: sudo bash enable-images.sh /path/to/postafly-images-app.env" >&2; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAIN="${DOMAIN:-postafly.com.pk}"
IMG_HOST="img.$DOMAIN"
STAMP="$(date +%Y%m%d)"

echo "==> Certificate for $IMG_HOST"
if [ ! -d "/etc/letsencrypt/live/$IMG_HOST" ]; then
  certbot certonly --dns-cloudflare \
    --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
    --dns-cloudflare-propagation-seconds 30 \
    -d "$IMG_HOST" --non-interactive --agree-tos --register-unsafely-without-email \
    --deploy-hook "systemctl reload nginx"
else
  echo "already have one"
fi

echo "==> nginx"
[ -f "/etc/nginx/sites-available/sengrid.bak-$STAMP-images" ] || cp -a /etc/nginx/sites-available/sengrid "/etc/nginx/sites-available/sengrid.bak-$STAMP-images"
install -d -m 755 /var/cache/nginx/postafly-img
chown www-data:www-data /var/cache/nginx/postafly-img
[ -f /etc/nginx/conf.d/postafly-img.conf ] && ! [ -f "/root/postafly-img.conf.bak-$STAMP" ] && cp -a /etc/nginx/conf.d/postafly-img.conf "/root/postafly-img.conf.bak-$STAMP" || true
sed "s/__IMG_HOST__/$IMG_HOST/g" "$SCRIPT_DIR/nginx-img.conf.template" > /etc/nginx/conf.d/postafly-img.conf
sed "s/__DOMAIN__/$DOMAIN/g" "$SCRIPT_DIR/nginx-https.conf.template" > /etc/nginx/sites-available/sengrid
if ! nginx -t; then
  echo "nginx test failed: restoring the previous site file" >&2
  cp -a "/etc/nginx/sites-available/sengrid.bak-$STAMP-images" /etc/nginx/sites-available/sengrid
  rm -f /etc/nginx/conf.d/postafly-img.conf
  exit 1
fi
systemctl reload nginx

echo "==> DNS record $IMG_HOST -> this server"
IMG_PROXIED="${IMG_PROXIED:-false}" IMG_HOST="$IMG_HOST" DOMAIN="$DOMAIN" python3 - <<'PY'
import json, os, re, urllib.request
token = re.search(r'=\s*(\S+)', open('/etc/letsencrypt/cloudflare.ini').read()).group(1)
def api(path, method='GET', body=None):
    req = urllib.request.Request('https://api.cloudflare.com/client/v4' + path, method=method,
        data=json.dumps(body).encode() if body else None,
        headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    try:
        return json.load(urllib.request.urlopen(req, timeout=30))
    except urllib.error.HTTPError as e:
        return json.load(e)
domain, host = os.environ['DOMAIN'], os.environ['IMG_HOST']
zone = api('/zones?name=' + domain)['result'][0]['id']
apex = [r for r in api(f'/zones/{zone}/dns_records?type=A&name={domain}')['result']]
ip = apex[0]['content']
have = api(f'/zones/{zone}/dns_records?name={host}')['result']
if have:
    print(host, 'already has a record:', have[0]['type'], have[0]['content'], 'proxied=' + str(have[0]['proxied']))
else:
    res = api(f'/zones/{zone}/dns_records', 'POST', {'type': 'A', 'name': host, 'content': ip, 'ttl': 300 if os.environ['IMG_PROXIED'] != 'true' else 1, 'proxied': os.environ['IMG_PROXIED'] == 'true'})
    print('created A', host, '->', ip, 'proxied=' + os.environ['IMG_PROXIED'] if res.get('success') else 'FAILED ' + json.dumps(res.get('errors')))
PY

echo "==> Backend picture settings"
ENV_FILE=/opt/sengrid/backend.env
[ -f "/root/backend.env.bak-$STAMP-images" ] || cp -a "$ENV_FILE" "/root/backend.env.bak-$STAMP-images"   # first run only: later runs keep the original backup
setvar() { if grep -q "^$1=" "$ENV_FILE"; then sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"; else echo "$1=$2" >> "$ENV_FILE"; fi; }
setvar SENGRID_IMAGES_ENDPOINT "http://10.10.1.10:9000"
setvar SENGRID_IMAGES_BUCKET "postafly-images"
setvar SENGRID_IMAGES_PUBLIC_BASE_URL "https://$IMG_HOST"
setvar SENGRID_IMAGES_ACCESS_KEY "$(grep -E '^SENGRID_IMAGES_ACCESS_KEY=' "$CRED" | cut -d= -f2-)"
setvar SENGRID_IMAGES_SECRET_KEY "$(grep -E '^SENGRID_IMAGES_SECRET_KEY=' "$CRED" | cut -d= -f2-)"
echo "settings written (backend not restarted yet)"

echo "Done. Note: the DNS record is DNS-only. To also use Cloudflare's CDN, switch it to proxied in the"
echo "Cloudflare dashboard (the zone's SSL mode must be Full or Full (strict); port 80 is not public here, so Flexible cannot work)."
