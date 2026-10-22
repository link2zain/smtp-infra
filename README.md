# Sengrid Infra

Docker Compose and configuration files for running the Sengrid platform infrastructure locally and in production.

## Services

| Service | Image | Ports | Purpose |
|---|---|---|---|
| PostgreSQL | `postgres:16-alpine` | 5432 | Primary database |
| Redis | `redis:7-alpine` | 6379 | Caching / rate limiting |
| RabbitMQ | `rabbitmq:3-management-alpine` | 5672, 15672 | Email queue |
| Mailpit | `axllent/mailpit` | 1025 (SMTP), 8025 (UI) | Local SMTP dev server |
| MinIO | `minio/minio` | 9000, 9001 | Object storage |
| Prometheus | `prom/prometheus` | 9090 | Metrics collection |
| Grafana | `grafana/grafana` | 3000 | Dashboards |
| local-relay | `boky/postfix` | 2525 | Local Postfix relay (optional) |

## Quick Start

```bash
# Start all core services — --compatibility makes Compose honor the deploy.resources.limits
# CPU/memory caps set on every service below; without it they're silently ignored (that key only
# applies natively under `docker stack deploy`/Swarm mode).
docker compose --compatibility up -d

# Start with local Postfix relay
docker compose --compatibility --profile relay up -d

# Stop all
docker compose down
```

## Service UIs

| Service | URL | Credentials |
|---|---|---|
| RabbitMQ Management | http://localhost:15672 | See `.env` → `RABBITMQ_DEFAULT_USER` / `RABBITMQ_DEFAULT_PASS` |
| Mailpit | http://localhost:8025 | — |
| MinIO Console | http://localhost:9001 | See `.env` → `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` |
| Prometheus | http://localhost:9090 | — |
| Grafana | http://localhost:3000 | See `.env` → `GRAFANA_ADMIN_PASSWORD` |

## Prometheus

Scrapes the Spring Boot backend at `http://host.docker.internal:8080/actuator/prometheus` every 15 seconds. Config: `prometheus/prometheus.yml`.

`host.docker.internal` only resolves to *this* Docker host (the compose file adds the `extra_hosts` entry needed for that to work on native Linux Engine, not just Docker Desktop) — it works out of the box only when the backend runs as a sibling container on the same single host as this compose stack. **In the multi-VM production layout below, Prometheus (VM4) and the backend (VM1) are different hosts**, so `host.docker.internal` can never reach it there; edit `prometheus/prometheus.yml`'s `targets` to VM1's actual IP or hostname instead.

## Production Deployment

For production, do **not** use this Docker Compose file directly. Instead:

- Run PostgreSQL, Redis, and RabbitMQ as managed services or on a dedicated **VM2**
- Run Postfix on **VM3** with multiple IPs bound for IP pool routing (see backend README)
- Run MinIO, Prometheus, and Grafana on **VM4**

### VM Layout

| VM | Role | Services |
|---|---|---|
| VM1 | App | Spring Boot backend + Nginx (frontend) |
| VM2 | Database | PostgreSQL 16 + Redis 7 |
| VM3 | Mail | Postfix (multi-IP) + RabbitMQ |
| VM4 | Infra | MinIO + Prometheus + Grafana |

### Postfix IP Pool Setup (VM3)

Each IP pool maps to a separate Postfix listener port in `/etc/postfix/master.cf`:

```
10025  inet  n - n - - smtpd -o smtp_bind_address=<TRANSACTIONAL_IP_1>
10026  inet  n - n - - smtpd -o smtp_bind_address=<TRANSACTIONAL_IP_2>
10030  inet  n - n - - smtpd -o smtp_bind_address=<MARKETING_IP_1>
10031  inet  n - n - - smtpd -o smtp_bind_address=<MARKETING_IP_2>
10040  inet  n - n - - smtpd -o smtp_bind_address=<WARMUP_IP_1>
10050  inet  n - n - - smtpd -o smtp_bind_address=<DEDICATED_TENANT_IP>
```

Each IP requires:
- PTR / rDNS record pointing to the mail hostname
- SPF DNS record: `v=spf1 ip4:<IP> ~all`
- DKIM signing via OpenDKIM
- DMARC DNS record

## Environment Variables (Production)

Override these when deploying the backend:

```env
SPRING_DATASOURCE_URL=jdbc:postgresql://<VM2_IP>:5432/sengrid
SPRING_DATASOURCE_USERNAME=sengrid
SPRING_DATASOURCE_PASSWORD=<strong_password>
SPRING_RABBITMQ_HOST=<VM3_IP>
SPRING_MAIL_HOST=<VM3_IP>
SENGRID_JWT_SECRET=<64_char_random_secret>
SENGRID_CORS_ALLOWED_ORIGINS=https://yourdomain.com
SENGRID_TRACKING_BASE_URL=https://yourdomain.com
```

## DNS and mail identity for postafly.com.pk (state on 2026-10-22)

Cloudflare zone `postafly.com.pk`: A for the apex/www (web) and smtp-mail-1/2/3 (the three sending IPs,
each with matching reverse DNS); apex SPF (the three IPs + Cloudflare Email Routing); `_spf` helper
record that customers include; SPF `v=spf1 a -all` on each smtp-mail-N hostname; DMARC; DKIM key
`postafly1._domainkey` for the platform's own emails (private half only in `backend.env` as
`SENGRID_MAIL_SYSTEM_DKIM_*`, never in git); `bounces.postafly.com.pk` MX to smtp-mail-1 plus SPF.
Bounce mailbox setup: `production-9vm/mail/bounce-mailbox.sh`.

## Picture hosting (image library), live since 2026-10-22

Customers upload pictures in the console ("Pictures") and use the public link in emails.
- **Files:** MinIO bucket `postafly-images` on the storage pair (10.10.1.10/.11). Created by
  `production-9vm/storage/images-bucket.sh` (run on smtp-storage-1): public read of single files only (no
  listing), plus a service account `postafly-images-app` limited to that one bucket. Its password is in
  `/root/postafly-images-app.env` on smtp-storage-1 and as `SENGRID_IMAGES_SECRET_KEY` in the backend env.
- **Public address:** `https://img.postafly.com.pk/<32 hex>.<jpg|png|gif>`. nginx on smtp-app
  (`production-9vm/app/nginx-img.conf.template`, installed by `production-9vm/app/enable-images.sh`) serves
  only that exact shape, fetches from MinIO over the private network, and keeps a 10-minute copy
  (`proxy_cache_use_stale` keeps pictures showing if a storage node is briefly down). The DNS record is
  DNS-only (grey cloud): Cloudflare's CDN is optional and needs the zone's SSL mode on Full/Full (strict).
- **Uploads:** the main site's nginx allows 11 MB for `/api/v1/images` (default is 1 MB). The backend accepts
  10 MB, shrinks to 1200 px wide, and stores at most 2 MB per picture.
- **Limits:** per plan `plan_limits.image_storage_mb` (free 200 MB, starter 1 GB, growth 5 GB, business 20 GB,
  enterprise 100 GB), override per organization in `organization_quota_overrides.image_storage_mb`.
- **Backend settings:** `SENGRID_IMAGES_ENDPOINT / _BUCKET / _PUBLIC_BASE_URL / _ACCESS_KEY / _SECRET_KEY`.
  Leave the endpoint empty to switch the feature off (the Pictures page then says so).
- **Known gap:** nothing deletes an organization's pictures when the organization itself is removed (there is
  no organization-deletion flow yet), so such files would have to be removed from the bucket by hand.
