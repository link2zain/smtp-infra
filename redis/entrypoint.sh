#!/bin/sh
set -e
# An empty REDIS_PASSWORD would render as a blank "requirepass" line below, which Redis parses as
# authentication disabled rather than as a config error — fail loudly instead, matching the
# "stack fails to start if any password is left blank" guarantee .env.example documents.
if [ -z "$REDIS_PASSWORD" ]; then
    echo "FATAL: REDIS_PASSWORD is empty. Refusing to start Redis without authentication." >&2
    exit 1
fi
# Render redis.conf from template, substituting REDIS_PASSWORD env var
sed "s|\${REDIS_PASSWORD}|${REDIS_PASSWORD}|g" \
    /usr/local/etc/redis/redis.conf.template \
    > /usr/local/etc/redis/redis.conf
exec redis-server /usr/local/etc/redis/redis.conf
