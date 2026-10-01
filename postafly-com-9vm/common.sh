#!/bin/bash
# Shared helpers for every tier's setup.sh. Sourced, never run directly.
set -euo pipefail

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$COMMON_DIR/env.sh"

TARGET_DIR="/opt/sengrid"
# Secrets are pushed to the VM by the operator right before running setup.sh (see README.md) and
# deleted afterwards -- they are never stored in this repo. /dev/shm is RAM-backed.
SECRETS_FILE="${SECRETS_FILE:-/dev/shm/postafly-com-secrets.env}"

fatal() { echo "FATAL: $*" >&2; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || fatal "Run this with sudo: sudo bash setup.sh"
}

load_secrets() {
  [ -f "$SECRETS_FILE" ] || fatal "$SECRETS_FILE not found -- push this tier's secrets first (see README.md)"
  set -a; source "$SECRETS_FILE"; set +a
}

# Fails loudly if any named secret is missing/empty/still a placeholder. A silent default here is
# exactly how a literal "REPLACE_ME" once became a live production password.
require_secret() {
  local name value
  for name in "$@"; do
    value="${!name:-}"
    if [ -z "$value" ] || [[ "$value" == REPLACE* ]]; then
      fatal "secret $name is missing or still a placeholder in $SECRETS_FILE"
    fi
  done
}

install_docker() {
  echo "==> Installing Docker (skipped if already present)"
  if command -v docker &>/dev/null; then
    echo "    docker already installed: $(docker --version)"
    return
  fi
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
}

# SSH is always allowed first: ufw defaults to deny-incoming once enabled, and enabling it
# without an SSH rule locks out the very session running the install.
ufw_begin() {
  command -v ufw &>/dev/null || fatal "ufw is not installed"
  ufw allow 22/tcp comment 'SSH' >/dev/null
}

# allow_from <port> <comment> <source>...   (each source is an IP or CIDR)
# Containers that need these rules must use network_mode: host -- Docker-published ports bypass
# ufw's source filtering entirely.
allow_from() {
  local port="$1" comment="$2" src
  shift 2
  for src in "$@"; do
    ufw allow from "$src" to any port "$port" proto tcp comment "$comment" >/dev/null
  done
}

ufw_commit() {
  ufw --force enable >/dev/null
  ufw status numbered
}
