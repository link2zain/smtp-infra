#!/bin/bash
# Wraps the official postgres entrypoint: on first boot (empty data volume), clones the primary
# via pg_basebackup instead of running initdb. The -R flag makes pg_basebackup write
# standby.signal + postgresql.auto.conf (primary_conninfo) itself, so once this hands off to the
# real entrypoint, Postgres starts straight into streaming-replica mode with no further config.
# On every later restart, the data directory is already populated, so this step is skipped
# entirely and replication just resumes.
set -e

if [ -z "$(ls -A "$PGDATA" 2>/dev/null)" ]; then
  echo "PGDATA is empty — cloning from primary ($PRIMARY_HOST) via pg_basebackup..."
  until gosu postgres pg_basebackup -h "$PRIMARY_HOST" -D "$PGDATA" -U "$PGUSER" -Fp -Xs -P -R; do
    echo "Primary not reachable yet, retrying in 5s..."
    sleep 5
  done
  echo "Base backup complete — starting as a streaming replica."
else
  echo "PGDATA already populated — skipping base backup, resuming replication."
fi

exec docker-entrypoint.sh postgres
