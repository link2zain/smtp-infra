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
# Start all core services
docker compose up -d

# Start with local Postfix relay
docker compose --profile relay up -d

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
