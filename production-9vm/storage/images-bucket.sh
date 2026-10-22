#!/usr/bin/env bash
# Picture storage for the image library. Run ONCE on smtp-storage-1 (10.10.1.10) as root:
#
#   sudo ./images-bucket.sh
#
# What it sets up on the MinIO cluster:
#   * bucket postafly-images
#   * public READ of single files only (s3:GetObject). Listing the bucket is NOT allowed to anyone
#     anonymous, so nobody can enumerate other customers' pictures. The public never talks to MinIO
#     directly anyway: nginx on smtp-app serves https://img.postafly.com.pk/<key> and fetches from here.
#   * a service account "postafly-images-app" that can ONLY put/get/delete objects in that one bucket
#     (the backend uses it; the cluster root password never leaves this server)
#
# The service account's password is generated here and written to /root/postafly-images-app.env
# (root-only). Copy its two values into /opt/sengrid/backend.env on smtp-app:
#   SENGRID_IMAGES_ENDPOINT=http://10.10.1.10:9000
#   SENGRID_IMAGES_ACCESS_KEY=postafly-images-app
#   SENGRID_IMAGES_SECRET_KEY=<from the file>
#   SENGRID_IMAGES_BUCKET=postafly-images
#   SENGRID_IMAGES_PUBLIC_BASE_URL=https://img.postafly.com.pk
# Re-running is safe: existing pieces are left alone and a saved password is NOT regenerated.
set -euo pipefail

BUCKET="${BUCKET:-postafly-images}"
APP_USER="${APP_USER:-postafly-images-app}"
ENV_FILE="${ENV_FILE:-/opt/sengrid/.env}"
CRED_FILE="/root/postafly-images-app.env"
MC_IMAGE="${MC_IMAGE:-quay.io/minio/mc:latest}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"

# cluster root credentials come from the same file docker compose uses; they are never printed
root_user="$(grep -E '^MINIO_ROOT_USER=' "$ENV_FILE" | head -1 | cut -d= -f2-)"
root_pass="$(grep -E '^MINIO_ROOT_PASSWORD=' "$ENV_FILE" | head -1 | cut -d= -f2-)"
[ -n "$root_user" ] && [ -n "$root_pass" ] || { echo "could not read the MinIO root credentials from $ENV_FILE" >&2; exit 1; }

# The password is saved BEFORE it is used, so a failure part-way can never leave an account whose password is lost.
fresh=no
if [ -f "$CRED_FILE" ]; then
  app_pass="$(grep -E '^SENGRID_IMAGES_SECRET_KEY=' "$CRED_FILE" | cut -d= -f2-)"
else
  app_pass="$(openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | head -c 40)"
  umask 077
  printf 'SENGRID_IMAGES_ACCESS_KEY=%s\nSENGRID_IMAGES_SECRET_KEY=%s\n' "$APP_USER" "$app_pass" > "$CRED_FILE"
  chmod 600 "$CRED_FILE"
  fresh=yes
fi

cat > "$work/anon.json" <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":["*"]},"Action":["s3:GetObject"],"Resource":["arn:aws:s3:::${BUCKET}/*"]}]}
JSON
cat > "$work/rw.json" <<JSON
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["s3:PutObject","s3:GetObject","s3:DeleteObject"],"Resource":["arn:aws:s3:::${BUCKET}/*"]},
 {"Effect":"Allow","Action":["s3:GetBucketLocation"],"Resource":["arn:aws:s3:::${BUCKET}"]}
]}
JSON
printf 'MC_HOST_l=http://%s:%s@127.0.0.1:9000\nAPP_PASS=%s\nFRESH=%s\n' "$root_user" "$root_pass" "$app_pass" "$fresh" > "$work/env"
chmod 600 "$work/env"

docker run --rm --network host --env-file "$work/env" -v "$work:/s:ro" -e BUCKET="$BUCKET" -e APP_USER="$APP_USER" \
  --entrypoint /bin/sh "$MC_IMAGE" -c '
set -e
mc mb --ignore-existing "l/$BUCKET"
mc anonymous set-json /s/anon.json "l/$BUCKET"
mc admin policy create l "$BUCKET-rw" /s/rw.json >/dev/null 2>&1 || true
if mc admin user info l "$APP_USER" >/dev/null 2>&1; then
  if [ "$FRESH" = "yes" ]; then
    # an account exists but no password was saved for it: start it over with the new, saved password
    mc admin user remove l "$APP_USER" >/dev/null
    mc admin user add l "$APP_USER" "$APP_PASS"
    echo "service account $APP_USER re-created with a new saved password"
  else
    echo "service account $APP_USER already exists (password left unchanged)"
  fi
else
  mc admin user add l "$APP_USER" "$APP_PASS"
fi
mc admin policy attach l "$BUCKET-rw" --user "$APP_USER" >/dev/null 2>&1 || true
echo "--- bucket policy for anonymous users:"; mc anonymous get "l/$BUCKET"
echo "--- service account:"; mc admin user info l "$APP_USER"
'

echo "service account password is in $CRED_FILE (root-only)"
echo done
