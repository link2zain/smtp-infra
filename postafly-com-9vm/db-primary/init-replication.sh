#!/bin/bash
# Runs automatically exactly once, only when the data volume is freshly initialized (the official
# postgres image executes everything in /docker-entrypoint-initdb.d/ on first boot only). Creates
# the replication role the secondary connects as, and lets that ONE host (not a subnet) open
# replication connections in pg_hba.conf.
set -e

if [ -z "$REPLICATION_PASSWORD" ]; then
  echo "FATAL: REPLICATION_PASSWORD is empty. Refusing to create an unusable replication role." >&2
  exit 1
fi
if [ -z "$REPLICA_IP" ]; then
  echo "FATAL: REPLICA_IP is empty. Refusing to guess who may replicate." >&2
  exit 1
fi

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '$REPLICATION_PASSWORD';
EOSQL

echo "host replication replicator ${REPLICA_IP}/32 md5" >> "$PGDATA/pg_hba.conf"
