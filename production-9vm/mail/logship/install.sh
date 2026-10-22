#!/bin/bash
# Installs the delivery log shipper on a mail server. Run as root, from this folder:
#
#   sudo bash install.sh /path/to/token-file
#
# The token file holds the shared secret (one line). It must be the same value as SENGRID_RELAY_INGEST_TOKEN in
# /opt/sengrid/backend.env on smtp-app. Safe to run again (it updates the script and restarts the service).
#
# What it does:
#   * creates a locked-down service user, installs the script and the systemd unit
#   * stores the secret readable only by that user
#   * turns on Postfix's TLS log line (smtp_tls_loglevel=1) so each delivery can say whether it was encrypted
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo" >&2; exit 1; }
TOKEN_SRC="${1:-}"
[ -f "$TOKEN_SRC" ] || { echo "usage: sudo bash install.sh /path/to/token-file" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

id postafly-logship >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin postafly-logship

install -d -m 755 /opt/postafly-logship
install -m 755 "$HERE/postafly-logship.py" /opt/postafly-logship/postafly-logship.py

install -d -m 750 -o root -g postafly-logship /etc/postafly-logship
install -m 640 -o root -g postafly-logship "$TOKEN_SRC" /etc/postafly-logship/token

install -m 644 "$HERE/postafly-logship.service" /etc/systemd/system/postafly-logship.service

# one extra log line per new TLS connection, nothing more
if [ "$(postconf -h smtp_tls_loglevel)" != "1" ]; then
  postconf -e "smtp_tls_loglevel = 1"
  systemctl reload postfix
fi

systemctl daemon-reload
systemctl enable postafly-logship >/dev/null 2>&1
systemctl restart postafly-logship
sleep 3
systemctl --no-pager --lines=8 status postafly-logship || true
echo "installed. Watch it with: journalctl -u postafly-logship -f"
