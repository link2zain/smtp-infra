#!/bin/bash
# Runs automatically exactly once, only when the data volume is freshly initialized (the official
# postgres image executes everything in /docker-entrypoint-initdb.d/ on first boot only). Creates
# the replication role smtp-db-replica connects as, and opens pg_hba.conf to the private subnet
# for replication connections specifically (not general access — that's still POSTGRES_PASSWORD).
set -e

if [ -z "$REPLICATION_PASSWORD" ]; then
  echo "FATAL: REPLICATION_PASSWORD is empty. Refusing to create an unusable replication role." >&2
  exit 1
fi

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '$REPLICATION_PASSWORD';
EOSQL

echo "host replication replicator 10.10.1.0/24 md5" >> "$PGDATA/pg_hba.conf"
