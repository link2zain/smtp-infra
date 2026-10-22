#!/bin/bash
# Fetches the free DB-IP "IP to Country Lite" database (https://db-ip.com, CC BY 4.0) that turns a reader's address
# into a country on opens and clicks. Run as root on smtp-app. Safe to run again; it only replaces the file after the
# new one has been checked.
#
#   sudo bash geoip-update.sh                 # now
#   (monthly) /etc/cron.d/postafly-geoip:  17 4 5 * *  root  /opt/sengrid/geoip/geoip-update.sh >>/var/log/postafly-geoip.log 2>&1
#
# The backend reads /opt/sengrid/geoip/dbip-country-lite.mmdb (SENGRID_GEOIP_DATABASE in backend.env) and notices a
# replaced file within ten minutes, so no restart is needed. DB-IP asks for a visible credit where the data is
# used; the Analytics page shows "IP Geolocation by DB-IP" next to the countries.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 1; }
DIR=/opt/sengrid/geoip
TARGET="$DIR/dbip-country-lite.mmdb"
install -d -m 755 "$DIR"

# a new file appears at the start of each month; fall back to last month's if this month's is not out yet
for months_ago in 0 1; do
  month=$(date -u -d "-${months_ago} month" +%Y-%m)
  url="https://download.db-ip.com/free/dbip-country-lite-${month}.mmdb.gz"
  tmp=$(mktemp -p "$DIR" .download.XXXXXX)
  if curl -fsS -m 180 -o "$tmp.gz" "$url" && gzip -dc "$tmp.gz" > "$tmp" 2>/dev/null; then
    # sanity: a real database is several MB and ends with MaxMind-format metadata
    size=$(stat -c %s "$tmp")
    if [ "$size" -gt 2000000 ] && tail -c 200000 "$tmp" | grep -aq "MaxMind.com"; then
      chmod 644 "$tmp"
      mv -f "$tmp" "$TARGET"
      rm -f "$tmp.gz"
      echo "$(date -u +%FT%TZ) installed dbip-country-lite-${month} ($size bytes)"
      exit 0
    fi
    echo "$(date -u +%FT%TZ) $url did not look like a database, skipped" >&2
  fi
  rm -f "$tmp" "$tmp.gz"
done

echo "$(date -u +%FT%TZ) could not fetch a new country database; keeping the current one" >&2
[ -f "$TARGET" ] || exit 1
