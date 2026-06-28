#!/usr/bin/env bash
# Backup Postgres, RabbitMQ, and MinIO volumes.
# Run from the infra/ directory on the host where docker-compose is running.
# Usage: ./backup.sh [backup_dir]
# Default backup_dir: ./backups/<ISO-date>

set -euo pipefail

BACKUP_DIR="${1:-./backups/$(date -u +%Y-%m-%dT%H-%M-%SZ)}"
mkdir -p "$BACKUP_DIR"

echo "[backup] Writing to $BACKUP_DIR"

# Postgres — pg_dump via the running container
echo "[backup] Dumping Postgres..."
docker compose exec -T postgres pg_dump \
  -U "${POSTGRES_USER:-sengrid}" \
  "${POSTGRES_DB:-sengrid}" \
  | gzip > "$BACKUP_DIR/postgres.sql.gz"
echo "[backup] Postgres done."

# RabbitMQ — export definitions (queues, exchanges, bindings, vhosts)
echo "[backup] Exporting RabbitMQ definitions..."
docker compose exec -T rabbitmq rabbitmqctl export_definitions - \
  | gzip > "$BACKUP_DIR/rabbitmq-definitions.json.gz"
echo "[backup] RabbitMQ done."

# MinIO — copy bucket data from the named volume via a temporary busybox container
echo "[backup] Archiving MinIO data..."
docker run --rm \
  -v smtp-infra_minio_data:/minio_data:ro \
  -v "$(pwd)/$BACKUP_DIR:/backup" \
  busybox \
  tar czf /backup/minio-data.tar.gz -C /minio_data .
echo "[backup] MinIO done."

echo "[backup] All backups written to $BACKUP_DIR"
ls -lh "$BACKUP_DIR"
