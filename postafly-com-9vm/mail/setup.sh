#!/bin/bash
# Run on Mail 1, Mail 2 AND Mail 3 as: sudo bash setup.sh   (identical script on all three)
# Needs secrets RABBITMQ_ERLANG_COOKIE and RABBITMQ_DEFAULT_PASS (see ../README.md) -- the same
# values on all three nodes. Sets up:
#   1. RabbitMQ (Docker) joining the 3-node cluster via classic_config peer discovery
#   2. Postfix (native) -- ONE default listener per node for now, as a relay for the website VM
#      only. Per-pool outbound IP binding (MULTI_IP_POOL_PLAN.md) comes once real IPs exist.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

require_root
load_secrets
require_secret RABBITMQ_ERLANG_COOKIE RABBITMQ_DEFAULT_PASS
install_docker

MY_HOSTNAME="$(hostname)"
[[ " ${MAIL_HOSTS[*]} " == *" $MY_HOSTNAME "* ]] || fatal "hostname '$MY_HOSTNAME' is not one of: ${MAIL_HOSTS[*]}"

echo "==> /etc/hosts entries so the 3 mail nodes resolve each other (no internal DNS here)"
for entry in "$MAIL1_IP mail-1" "$MAIL2_IP mail-2" "$MAIL3_IP mail-3"; do
  grep -qF "$entry" /etc/hosts || echo "$entry" >> /etc/hosts
done

echo "==> Setting up $TARGET_DIR (RabbitMQ)"
mkdir -p "$TARGET_DIR"
cp "$SCRIPT_DIR/docker-compose.yml" "$SCRIPT_DIR/rabbitmq.conf" "$TARGET_DIR/"

ENV_FILE="$TARGET_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  echo "==> $ENV_FILE already exists — leaving it alone"
else
  echo "==> Writing $ENV_FILE"
  {
    echo "RABBITMQ_NODENAME=rabbit@$MY_HOSTNAME"
    echo "RABBITMQ_ERLANG_COOKIE=$RABBITMQ_ERLANG_COOKIE"
    echo "RABBITMQ_DEFAULT_USER=sengrid"
    echo "RABBITMQ_DEFAULT_PASS=$RABBITMQ_DEFAULT_PASS"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
fi

echo "==> Installing Postfix (native, non-interactive)"
if ! command -v postfix &>/dev/null; then
  debconf-set-selections <<< "postfix postfix/main_mailer_type select Internet Site"
  debconf-set-selections <<< "postfix postfix/mailname string $MY_HOSTNAME.$DOMAIN"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postfix
else
  echo "    postfix already installed"
fi

echo "==> Configuring Postfix as a relay for the website VM only (no auth, no TLS -- matches"
echo "    SmtpMailProvider's JavaMailSenderImpl config: mail.smtp.auth=false, starttls=false)"
postconf -e "myhostname = $MY_HOSTNAME.$DOMAIN"
postconf -e "mydomain = $DOMAIN"
# $myhostname, not $mydomain: this box is a relay, not the domain's mail server. With $mydomain,
# unqualified addresses (the postmaster -> root system alias) became root@$DOMAIN and were sent to
# the domain's real MX instead of staying local.
postconf -e "myorigin = \$myhostname"
postconf -e "inet_interfaces = all"
postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost"
# Only the website VM may relay -- not the rest of this shared LAN (a compromised neighbour must
# not be able to send mail through our IPs).
postconf -e "mynetworks = 127.0.0.0/8, $WEBSITE_IP/32"
postconf -e "smtpd_relay_restrictions = permit_mynetworks, reject_unauth_destination"
postconf -e "disable_vrfy_command = yes"
postconf -e "smtpd_banner = \$myhostname ESMTP"
systemctl restart postfix
systemctl enable postfix

echo "==> Firewall"
ufw_begin
allow_from 25 'postfix relay - website only' "$WEBSITE_IP"
PEERS=()
for ip in "$MAIL1_IP" "$MAIL2_IP" "$MAIL3_IP"; do
  [ "$ip" = "$(hostname -I | awk '{print $1}')" ] || PEERS+=("$ip")
done
allow_from 4369 'rabbitmq epmd - mail peers' "${PEERS[@]}"
allow_from 25672 'rabbitmq clustering - mail peers' "${PEERS[@]}"
allow_from 5672 'rabbitmq amqp - website' "$WEBSITE_IP"
allow_from 15672 'rabbitmq management ui - admin network' "$ADMIN_NET"
allow_from 15692 'rabbitmq prometheus - monitoring' "$MONITOR_IP"
ufw_commit

echo "==> Starting RabbitMQ"
cd "$TARGET_DIR"
docker compose --env-file .env up -d

echo "Done on $MY_HOSTNAME. RabbitMQ finishes clustering once all 3 nodes have run this script."
