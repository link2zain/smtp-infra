#!/bin/bash
# Run on BOTH Storage VMs as: sudo bash setup.sh   (identical script; MinIO works out which node it is)
# Needs secret MINIO_ROOT_PASSWORD (see ../README.md) -- the same value on both nodes.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

require_root
load_secrets
require_secret MINIO_ROOT_PASSWORD
install_docker

MINIO_IMAGE="quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z"
echo "==> MinIO image"
if docker image inspect "$MINIO_IMAGE" &>/dev/null; then
  echo "    $MINIO_IMAGE already present"
elif ls "$SCRIPT_DIR"/minio-images-*.tar.gz &>/dev/null; then
  # MinIO no longer publishes this image publicly, so the operator supplies a saved copy.
  gunzip -c "$SCRIPT_DIR"/minio-images-*.tar.gz | docker load
else
  fatal "MinIO's public images are gone: copy minio-images-*.tar.gz (docker save of $MINIO_IMAGE) next to this script"
fi

echo "==> Creating the two MinIO data directories on the data disk (/var)"
mkdir -p /var/minio-data/disk1 /var/minio-data/disk2

echo "==> Setting up $TARGET_DIR"
mkdir -p "$TARGET_DIR"
cp "$SCRIPT_DIR/docker-compose.yml" "$TARGET_DIR/"

ENV_FILE="$TARGET_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  echo "==> $ENV_FILE already exists — leaving it alone"
else
  echo "==> Writing $ENV_FILE"
  {
    echo "MINIO_ROOT_USER=sengrid-admin"
    echo "MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD"
    echo "STORAGE1_IP=$STORAGE1_IP"
    echo "STORAGE2_IP=$STORAGE2_IP"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
fi

echo "==> Firewall: S3 API from the two storage nodes + website, console from the admin network"
ufw_begin
allow_from 9000 'minio s3 api - storage nodes + website' "$STORAGE1_IP" "$STORAGE2_IP" "$WEBSITE_IP"
allow_from 9001 'minio console - admin network' "$ADMIN_NET"
ufw_commit

echo "==> Starting MinIO"
cd "$TARGET_DIR"
docker compose --env-file .env up -d

echo "Done. The cluster only forms once this has run on BOTH storage nodes."
