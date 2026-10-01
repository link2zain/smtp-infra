#!/bin/bash
# Environment definition for the postafly.com 9-VM deployment. Sourced by common.sh, never run
# directly. Everything environment-specific that a setup.sh needs (addresses, domain) lives here.

DOMAIN="postafly.com"

# 193.168.10.0/24 is a shared server LAN (it also holds unrelated servers), so services below are
# opened to specific VMs by IP -- never to the whole subnet.
WEBSITE_IP="193.168.10.80"
DB_PRIMARY_IP="193.168.10.81"
DB_SECONDARY_IP="193.168.10.82"
MAIL1_IP="193.168.10.83"
MAIL2_IP="193.168.10.84"
MAIL3_IP="193.168.10.85"
STORAGE1_IP="193.168.10.86"
STORAGE2_IP="193.168.10.87"
MONITOR_IP="193.168.10.88"

# Network the operators browse the admin UIs from (Grafana, Prometheus, RabbitMQ management,
# MinIO console). Only those UI ports are opened to it -- never data ports.
ADMIN_NET="192.168.10.0/24"

# Hostnames the VMs were provisioned with; RabbitMQ node names derive from these.
MAIL_HOSTS=(mail-1 mail-2 mail-3)
