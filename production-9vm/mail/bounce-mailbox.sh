#!/usr/bin/env bash
# Bounce mailbox for the relay. Run ONCE on smtp-mail-1 (10.10.1.7) as a sudo-capable user:
#
#   BOUNCE_IMAP_PASSWORD='<long random string>' ./bounce-mailbox.sh
#
# What it sets up (this is what was done by hand on 2026-10-22; this script makes it repeatable):
#   * Postfix accepts mail for bounces.postafly.com.pk, but ONLY addresses shaped bounce+<uuid>@...
#     (anything else gets "550 User unknown"), and files it into one private Maildir.
#     Relaying for strangers stays refused (reject_unauth_destination).
#   * Dovecot serves that Maildir over IMAP on the PRIVATE address only, to a single account
#     "bounces". The backend's ImapBounceWorker reads it, parses each bounce report, marks the
#     message BOUNCED and suppresses the address.
#   * ufw: port 25 open to the internet (public MX for the bounce domain), IMAP 143 only from the
#     app server (10.10.1.4).
#
# DNS this needs (Cloudflare, zone postafly.com.pk):
#   MX  bounces.postafly.com.pk  10 smtp-mail-1.postafly.com.pk
#   TXT bounces.postafly.com.pk  "v=spf1 include:_spf.postafly.com.pk ~all"
#
# Backend settings this pairs with (/opt/sengrid/backend.env on smtp-app):
#   SENGRID_RELAY_BOUNCE_DOMAIN=bounces.postafly.com.pk
#   SENGRID_RELAY_IMAP_BOUNCE_WORKER_ENABLED=true
#   SENGRID_RELAY_IMAP_BOUNCE_WORKER_HOST=10.10.1.7      PORT=143      SSL=false
#   SENGRID_RELAY_IMAP_BOUNCE_WORKER_USERNAME=bounces
#   SENGRID_RELAY_IMAP_BOUNCE_WORKER_PASSWORD=<same as BOUNCE_IMAP_PASSWORD>
set -euo pipefail

: "${BOUNCE_IMAP_PASSWORD:?set BOUNCE_IMAP_PASSWORD}"
PRIVATE_IP="${PRIVATE_IP:-10.10.1.7}"
APP_IP="${APP_IP:-10.10.1.4}"
DOMAIN="bounces.postafly.com.pk"

export DEBIAN_FRONTEND=noninteractive
sudo apt-get install -y dovecot-imapd

# Mailbox owner and folder
id vmail >/dev/null 2>&1 || sudo useradd -u 5000 -U -M -d /var/vmail -s /usr/sbin/nologin vmail
sudo mkdir -p /var/vmail/bounces/{new,cur,tmp}
sudo chown -R vmail:vmail /var/vmail
sudo chmod -R 700 /var/vmail

# Postfix: only bounce+<uuid>@bounces.postafly.com.pk is a real address
sudo cp -a /etc/postfix/main.cf "/etc/postfix/main.cf.bak-$(date +%Y%m%d)"
echo '/^bounce\+[0-9a-fA-F-]{36}@bounces\.postafly\.com\.pk$/   bounces/' | sudo tee /etc/postfix/vmailbox_bounces.regexp >/dev/null
sudo postconf -e "virtual_mailbox_domains = ${DOMAIN}"
sudo postconf -e "virtual_mailbox_base = /var/vmail"
sudo postconf -e "virtual_mailbox_maps = regexp:/etc/postfix/vmailbox_bounces.regexp"
sudo postconf -e "virtual_uid_maps = static:5000"
sudo postconf -e "virtual_gid_maps = static:5000"
sudo postconf -e "virtual_minimum_uid = 100"
sudo postconf -e "smtpd_helo_required = yes"
sudo postfix check

# Dovecot 2.4: one account, private address only, no system (PAM) logins
sudo cp -a /etc/dovecot "/etc/dovecot.bak-$(date +%Y%m%d)"
sudo sed -i 's|^!include auth-system.conf.ext|#!include auth-system.conf.ext|' /etc/dovecot/conf.d/10-auth.conf
printf 'bounces:%s\n' "$(sudo doveadm pw -s SHA512-CRYPT -p "${BOUNCE_IMAP_PASSWORD}")" | sudo tee /etc/dovecot/bounces.passwd >/dev/null
sudo chown root:dovecot /etc/dovecot/bounces.passwd
sudo chmod 640 /etc/dovecot/bounces.passwd
sudo tee /etc/dovecot/local.conf >/dev/null <<DOVECOT
# Postafly bounce mailbox: read by the backend over the private network only.
protocols = imap
listen = ${PRIVATE_IP}
ssl = no
auth_allow_cleartext = yes
auth_mechanisms = plain login

mail_driver = maildir
mail_path = /var/vmail/%{user}
mail_inbox_path = /var/vmail/%{user}
mail_home = /var/vmail

passdb passwd-file {
  passwd_file_path = /etc/dovecot/bounces.passwd
}

userdb static {
  fields {
    uid = vmail
    gid = vmail
    home = /var/vmail
  }
}
DOVECOT
sudo doveconf -n >/dev/null

sudo systemctl reload postfix
sudo systemctl restart dovecot

# Firewall
sudo ufw allow 25/tcp comment 'public MX for bounces.postafly.com.pk (virtual domain only; relay denied)'
sudo ufw allow from "${APP_IP}" to any port 143 proto tcp comment 'bounce mailbox IMAP: backend only'

echo "done. Check: from outside, RCPT to bounce+<uuid>@${DOMAIN} -> 250, anything else -> 550, relay -> 554."
