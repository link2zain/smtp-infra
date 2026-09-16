#!/bin/bash
# Run as: sudo bash setup.sh
# Identical script, run on smtp-mail-1, smtp-mail-2, AND smtp-mail-3. Sets up:
#   1. RabbitMQ (Docker, joins the 3-node cluster via classic_config peer discovery)
#   2. Postfix (native install) -- ONE default listener for now, not yet the multi-IP-pool
#      master.cf design from MULTI_IP_POOL_PLAN.md, because real distinct outbound IPs per pool
#      haven't been sourced yet (explicitly deferred). This mirrors how the original smtp-mail
#      VM was built: single instance, one IP, ready to extend once real IPs exist.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this with sudo: sudo bash setup.sh" >&2
  exit 1
fi

TARGET_DIR="/opt/sengrid"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MY_HOSTNAME="$(hostname)"

RABBITMQ_ERLANG_COOKIE_VALUE="REPLACE_WITH_YOUR_OWN_GENERATED_SECRET"
RABBITMQ_DEFAULT_PASS_VALUE="REPLACE_WITH_YOUR_OWN_GENERATED_SECRET"
for name_value in "RABBITMQ_ERLANG_COOKIE_VALUE:$RABBITMQ_ERLANG_COOKIE_VALUE" "RABBITMQ_DEFAULT_PASS_VALUE:$RABBITMQ_DEFAULT_PASS_VALUE"; do
  name="${name_value%%:*}"; value="${name_value#*:}"
  if [ "$value" = "REPLACE_WITH_YOUR_OWN_GENERATED_SECRET" ]; then
    echo "FATAL: edit this script and replace $name with a real generated secret" >&2
    echo "       (the exact same value on all 3 smtp-mail nodes) before running it." >&2
    exit 1
  fi
done

echo "==> Installing Docker (skipped if already present)"
if ! command -v docker &>/dev/null; then
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
else
  echo "    docker already installed: $(docker --version)"
fi

echo "==> Adding /etc/hosts entries so the 3 mail nodes can resolve each other by hostname"
# No internal DNS server in this environment -- RabbitMQ clustering needs smtp-mail-1/2/3 to
# resolve to each other's private IPs, so we hardcode it the same way a tiny /etc/hosts-based
# setup normally would.
for entry in "10.10.1.7 smtp-mail-1" "10.10.1.8 smtp-mail-2" "10.10.1.9 smtp-mail-3"; do
  if ! grep -qF "$entry" /etc/hosts; then
    echo "$entry" >> /etc/hosts
  fi
done

echo "==> Setting up $TARGET_DIR (RabbitMQ)"
mkdir -p "$TARGET_DIR"
cp "$SCRIPT_DIR/docker-compose.yml" "$TARGET_DIR/"
cp "$SCRIPT_DIR/rabbitmq.conf" "$TARGET_DIR/"

ENV_FILE="$TARGET_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  echo "==> $ENV_FILE already exists — leaving it alone"
else
  echo "==> Writing $ENV_FILE"
  {
    echo "RABBITMQ_NODENAME=rabbit@$MY_HOSTNAME"
    echo "RABBITMQ_ERLANG_COOKIE=$RABBITMQ_ERLANG_COOKIE_VALUE"
    echo "RABBITMQ_DEFAULT_USER=sengrid"
    echo "RABBITMQ_DEFAULT_PASS=$RABBITMQ_DEFAULT_PASS_VALUE"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
fi

echo "==> Installing Postfix (native, non-interactive) — single default listener for now"
if ! command -v postfix &>/dev/null; then
  debconf-set-selections <<< "postfix postfix/main_mailer_type select Internet Site"
  debconf-set-selections <<< "postfix postfix/mailname string $MY_HOSTNAME.postafly.pk"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postfix
else
  echo "    postfix already installed"
fi

echo "==> Configuring Postfix as a trusted-LAN relay for smtp-app (no auth, no TLS -- matches"
echo "    SmtpMailProvider's JavaMailSenderImpl config: mail.smtp.auth=false, starttls=false)"
postconf -e "myhostname = $MY_HOSTNAME.postafly.pk"
postconf -e "mydomain = postafly.pk"
postconf -e "myorigin = \$mydomain"
postconf -e "inet_interfaces = all"
postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost"
# Only the private subnet may relay through this box -- nothing from the public internet.
postconf -e "mynetworks = 127.0.0.0/8, 10.10.1.0/24"
postconf -e "smtpd_relay_restrictions = permit_mynetworks, reject_unauth_destination"
postconf -e "disable_vrfy_command = yes"
postconf -e "smtpd_banner = \$myhostname ESMTP"
systemctl restart postfix
systemctl enable postfix

echo "==> Firewall: SSH always allowed, then RabbitMQ + Postfix restricted to the subnet"
if command -v ufw &>/dev/null; then
  ufw allow 22/tcp comment 'SSH'
  ufw allow from 10.10.1.0/24 to any port 25 proto tcp comment 'postfix relay - internal only'
  ufw allow from 10.10.1.0/24 to any port 4369 proto tcp comment 'rabbitmq epmd - internal only'
  ufw allow from 10.10.1.0/24 to any port 5672 proto tcp comment 'rabbitmq amqp - internal only'
  ufw allow from 10.10.1.0/24 to any port 15672 proto tcp comment 'rabbitmq mgmt ui - internal only'
  ufw allow from 10.10.1.0/24 to any port 25672 proto tcp comment 'rabbitmq clustering - internal only'
  ufw --force enable
else
  echo "    ufw not found — configure a firewall manually to restrict the above to 10.10.1.0/24"
fi

echo "==> Starting RabbitMQ"
cd "$TARGET_DIR"
docker compose --env-file .env up -d

echo ""
echo "Done on $MY_HOSTNAME. RabbitMQ won't finish clustering until this same script has run on"
echo "all 3 smtp-mail nodes. Check with: docker exec \$(docker ps -qf name=rabbitmq) rabbitmqctl cluster_status"
echo "Postfix is already live and independent per-node (no clustering needed for an MTA relay)."
