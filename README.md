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

## Delivery results from the mail servers, live since 2026-10-22

Until now a message became `SENT` when our own Postfix accepted it, and nothing recorded what the receiving
server answered. Now each mail server reports it:
- **Shipper:** `production-9vm/mail/logship/` (`postafly-logship.py`, run by systemd as `postafly-logship`).
  It follows `/var/log/mail.log`, joins each customer message's Postfix lines by queue id (the envelope sender
  `bounce+<message id>@bounces.postafly.com.pk` names the message) and posts batches to
  `http://10.10.1.4:8080/api/v1/internal/delivery-events` with the header `X-Postafly-Relay-Token`.
  Install or update on a mail VM: copy the folder, then `sudo bash install.sh <token-file>`. The installer also
  sets `smtp_tls_loglevel = 1` so each delivery can say whether it was encrypted.
- **Token:** `SENGRID_RELAY_INGEST_TOKEN` in `/opt/sengrid/backend.env` (48 hex characters, same value in
  `/etc/postafly-logship/token` on each mail VM, readable by root and the service user only). Empty = endpoint off.
- **Private only:** the shippers use port 8080 on the private network (ufw allows 10.10.1.0/24); the public
  nginx answers 404 for `/api/v1/internal/`.
- **Result:** the message becomes `DELIVERED`, `BOUNCED` or `BLOCKED` (reputation/content/policy refusals, which
  never suppress the address); deferrals add a "delayed" event and the message stays "in transit". Events carry
  the SMTP code, enhanced status, the receiving server's reply, TLS and time taken. Safe to replay: events are
  unique per (message, id), so restarting the shipper or re-reading the log changes nothing.
- **Still needed:** the old bounce-mailbox path stays on as a backstop. Some servers (zmdservice.com at InMotion
  was one) accept mail for a mailbox that does not exist and only bounce later by email, or never; those show
  as delivered until the bounce email arrives.
- **Health:** Admin > Relay health lists each mail server's feed (silent for over 5 minutes shows as such).
- **Tests:** `python3 -m unittest test_logship` in that folder (the log-rotation test only runs on Linux).

## Opens and clicks: who made them (live since 2026-10-22)

- **Links reach the backend:** nginx now forwards `/track/` (open pixel, click redirect) and `/unsubscribe/` to the
  backend. Before this they fell through to the website's home page, so pixels, click links and unsubscribe links
  in sent emails did not work. Fixed in `production-9vm/app/nginx-https.conf.template`, `nginx.conf` and
  `postafly-com-9vm/website/nginx.conf` (live on postafly.com.pk; the postafly.com replica still needs the new file).
- **Click links are signed** (HMAC, `s=` parameter) with `SENGRID_TRACKING_LINK_SECRET`, which defaults to the JWT
  secret. A link whose address was changed, or that has no signature, answers 404 instead of redirecting.
- **Country:** free DB-IP Lite country file at `/opt/sengrid/geoip/dbip-country-lite.mmdb`
  (`SENGRID_GEOIP_DATABASE` in backend.env). `production-9vm/app/geoip-update.sh` fetches it; `/etc/cron.d/postafly-geoip`
  refreshes it on the 5th of each month and the backend notices a new file within ten minutes. CC BY 4.0: the
  Analytics page shows "IP Geolocation by DB-IP" beside the countries. No file = no countries, nothing else breaks.
- **Real visitor address** reaches the backend through Trubyte and nginx (checked on 2026-10-22). Only the network
  (`a.b.c.0/24`, or /48 for IPv6) is stored, never the full address.
- **Who counts:** each event is HUMAN, APPLE_PROXY (request from Apple's 17.0.0.0/8 block: Mail Privacy Protection
  pre-loading), MAIL_PROXY (Gmail/Yahoo image proxy) or BOT (scanner or script user agent, HEAD request, or a click
  within `sengrid.tracking.bot-click-seconds` = 3 s of delivery). Bots are kept but never counted or sent to
  webhooks. The Apple rule is a best guess (Apple's Private Relay partner ranges are not covered), so treat "likely
  read" as an estimate and check it against real traffic once customers send.

## Send API (V32), live since 2026-10-22

Customer documentation: `smtp-backend/docs/SEND_API.md`. Operations notes:
- **Limits:** the send endpoint accepts bodies up to 12 MB (nginx `location = /api/v1/mail/send`, so 7 MB of attachments fit); every other
  `/api/` path keeps nginx's 1 MB default. Up to 100 recipients per request, 7 MB of attachments, 10 files.
- **Rate limit:** about 20 requests/second per organization (burst 40), in memory on smtp-app. Override with `SENGRID_MAIL_RATE_LIMIT_PER_SECOND`
  and `SENGRID_MAIL_RATE_LIMIT_BURST`; `SENGRID_MAIL_MAX_RECIPIENTS_PER_REQUEST` and `SENGRID_MAIL_MAX_ATTACHMENT_BYTES` change the other caps.
- **Scheduled sends** wait in the database (`email_messages.status = SCHEDULED`, content in `email_batch_content`) and a job on smtp-app releases them
  every 15 s (`SENGRID_MAIL_SCHEDULED_POLL_MS`). Warm-up caps are checked at release; a message that cannot be released for 24 h is dropped.
  Attachments and scheduled content older than 7 days, and idempotency keys older than 24 h, are deleted hourly.
- **Webhooks** are delivered by up to 4 parallel workers and polled every 3 s (`sengrid.webhooks.retry-poll-ms`); the signature covers
  `"<X-Postafly-Timestamp>.<body>"`. Internal steps (queued, published, processing, retries) are never sent.
- **Rollback:** the V32 changes are additive with defaults, so the previous jar (`app.jar.bak-20261022-pre-send-api`) still runs against the migrated
  database. Database backup: `/var/backups/sengrid/pre-V32-20261022.sql.gz` on smtp-db-primary.
