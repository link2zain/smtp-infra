#!/usr/bin/env bash
# Backup Postgres, RabbitMQ, and MinIO volumes.
# Run from the infra/ directory on the host where docker-compose is running.
# Usage: ./backup.sh [backup_dir]
# Default backup_dir: ./backups/<ISO-date>

set -euo pipefail

# Load .env so POSTGRES_USER/POSTGRES_DB below match what the running containers were actually
# configured with — without this, a customized .env silently fell back to the sengrid/sengrid
# defaults, which pg_dump would fail against with a wrong-database/wrong-user error.
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

BACKUP_DIR="${1:-./backups/$(date -u +%Y-%m-%dT%H-%M-%SZ)}"
mkdir -p "$BACKUP_DIR"

echo "[backup] Writing to $BACKUP_DIR"

# Docker Compose names volumes <project-name>_<volume-name>, and the project name defaults to the
# containing directory's basename — this only worked by coincidence when the directory was named
# smtp-infra. Honor COMPOSE_PROJECT_NAME (from the environment or .env) the same way Compose does.
COMPOSE_PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$(pwd)")}"
MINIO_VOLUME="${COMPOSE_PROJECT}_minio_data"

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
echo "[backup] Archiving MinIO data from volume $MINIO_VOLUME..."
if ! docker volume inspect "$MINIO_VOLUME" >/dev/null 2>&1; then
  echo "[backup] ERROR: volume $MINIO_VOLUME does not exist — refusing to silently back up an empty/wrong volume." >&2
  echo "[backup] Set COMPOSE_PROJECT_NAME to match the running stack if this directory was renamed or deployed under a different project name." >&2
  exit 1
fi
docker run --rm \
  -v "$MINIO_VOLUME:/minio_data:ro" \
  -v "$(pwd)/$BACKUP_DIR:/backup" \
  busybox \
  tar czf /backup/minio-data.tar.gz -C /minio_data .
echo "[backup] MinIO done."

echo "[backup] All backups written to $BACKUP_DIR"
ls -lh "$BACKUP_DIR"
