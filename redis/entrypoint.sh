#!/bin/sh
set -e
# Render redis.conf from template, substituting REDIS_PASSWORD env var
sed "s|\${REDIS_PASSWORD}|${REDIS_PASSWORD}|g" \
    /usr/local/etc/redis/redis.conf.template \
    > /usr/local/etc/redis/redis.conf
exec redis-server /usr/local/etc/redis/redis.conf
