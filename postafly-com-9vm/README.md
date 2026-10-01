# postafly.com — 9-VM deployment

Same five tiers as `../production-9vm/` (postafly.com.pk), on the postafly.com VMs:

| Tier | VM | Address | Runs |
|---|---|---|---|
| `db-primary/` | db-primary | 193.168.10.81 | PostgreSQL 16 (primary) + Redis 7 |
| `db-replica/` | db-replication | 193.168.10.82 | PostgreSQL 16 streaming replica |
| `storage/` | storage-1, storage-2 | 193.168.10.86 / .87 | 2-node MinIO (EC:2) |
| `mail/` | mail-1, mail-2, mail-3 | 193.168.10.83 / .84 / .85 | 3-node RabbitMQ cluster + Postfix |
| `website/` | website-proxy | 193.168.10.80 | Spring Boot backend + frontend behind nginx |
| `monitor/` | monitoring | 193.168.10.88 | Prometheus + Grafana |

Run order: db-primary → db-replica → storage (both) → mail (all 3) → website → monitor.

## What differs from production-9vm

- **Shared LAN.** 193.168.10.0/24 also holds unrelated servers, so every firewall rule names the
  specific VMs that need access (`env.sh`) instead of trusting the subnet. Postfix relays for the
  website VM only. Admin UIs (Grafana, Prometheus, RabbitMQ management, MinIO console) are open to
  `ADMIN_NET` only.
- **Host networking everywhere a port is exposed.** Docker-published ports bypass ufw's per-source
  rules, so Postgres, Redis, Prometheus and Grafana use `network_mode: host` too.
- **Secrets are pushed at install time, never stored in git.** No placeholder swapping.
- **Storage VMs have one 1 TB disk each**, not 2×500 GB, so MinIO's two drives per node are
  directories on the same filesystem (see `storage/docker-compose.yml`).
- Domain is `postafly.com`; the backend's system-email sender comes from `SENGRID_MAIL_SYSTEM_FROM`.

## Secrets

Each `setup.sh` reads `/dev/shm/postafly-com-secrets.env` (RAM-backed), which the operator copies
to the VM just before running it and deletes afterwards. Each script lists the names it needs and
refuses to run if one is missing or still a placeholder. Secrets used: `POSTGRES_PASSWORD`,
`REPLICATION_PASSWORD`, `REDIS_PASSWORD`, `MINIO_ROOT_PASSWORD`, `RABBITMQ_ERLANG_COOKIE`,
`RABBITMQ_DEFAULT_PASS`, `SENGRID_JWT_SECRET`, `GRAFANA_ADMIN_PASSWORD`. The values that must
match across VMs are shared by construction because they come from the same file. The resulting
`.env` files on each VM (root-only, mode 600) are the permanent record.

## Running a tier

```bash
# from a machine with SSH access: copy this directory, push that tier's secrets, run, clean up
scp -r postafly-com-9vm <vm>:~/pc-deploy
ssh <vm> 'umask 077; cat > /dev/shm/postafly-com-secrets.env' < secrets-for-this-tier.env
ssh <vm> 'sudo bash ~/pc-deploy/<tier>/setup.sh'
ssh <vm> 'sudo shred -u /dev/shm/postafly-com-secrets.env; rm -rf ~/pc-deploy'
```

The website tier also needs `app.jar` and `frontend-dist/` copied into `website/` first.

The storage tier also needs `minio-images-*.tar.gz` copied into `storage/` first: MinIO stopped
publishing its community images and binaries, so the pinned release
(`RELEASE.2025-09-07T16-13-09Z`) is loaded from a saved copy. Keep that tarball somewhere safe --
it can't be re-downloaded.

## Not done yet

Public IPs / NAT, per-pool Postfix IP binding, DNS (SPF/DKIM/DMARC/PTR), TLS. Until TLS exists the
session cookie (Secure-flagged) won't work in a browser over plain HTTP.
