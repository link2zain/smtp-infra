# Production VM Specification

**Status:** the 9 machines below are being provisioned to this spec now. This is the target for the eventual production environment — the current live/tested deployment still runs on the original 4-VM dev/test setup (`smtp-app`, `smtp-db`, `smtp-mail`, `smtp-infra` on `193.168.10.x`). Production implementation work starts once these are built and confirmed to match this spec — testing continues on the existing 4-VM setup until then.

| Name | Role | vCPU | RAM | Storage |
|---|---|---|---|---|
| smtp-app | Frontend + Backend + Nginx (single instance) | 8 | 24 GB | 100 GB SSD |
| smtp-db-primary | PostgreSQL 16 + Redis 7 (writes) | 16 | 64 GB | 1 TB NVMe SSD |
| smtp-db-replica | PostgreSQL 16 streaming replica (failover + read offload) | 16 | 64 GB | 1 TB NVMe SSD |
| smtp-mail-1 | Postfix (transactional IP pool) + RabbitMQ cluster node | 8 | 24 GB | 300 GB SSD |
| smtp-mail-2 | Postfix (marketing IP pool) + RabbitMQ cluster node | 8 | 24 GB | 300 GB SSD |
| smtp-mail-3 | Postfix (warmup / dedicated-tenant IP pool) + RabbitMQ cluster node | 8 | 24 GB | 300 GB SSD |
| smtp-storage-1 | MinIO node 1 of 2 (2× 500 GB volumes, for erasure-coding minimum) | 6 | 24 GB | 2× 500 GB SSD |
| smtp-storage-2 | MinIO node 2 of 2 (2× 500 GB volumes, for erasure-coding minimum) | 6 | 24 GB | 2× 500 GB SSD |
| smtp-monitor | Prometheus + Grafana | 6 | 32 GB | 1 TB SSD |

**Why this shape (matches the actual codebase, not arbitrary):**
- `smtp-mail-1/2/3` map directly to `IpPool.PoolType` (`TRANSACTIONAL`, `MARKETING`, `WARMUP`/`DEDICATED`) already implemented in `smtp-backend`'s `com.sengrid.ippool` package — one dedicated mail-sending VM per pool type, so a reputation problem on one pool (e.g. marketing) can't touch another (e.g. transactional).
- `smtp-db-primary` + `smtp-db-replica` add the failover/read-offload redundancy the single-instance dev DB doesn't have.
- `smtp-storage-1/2` give MinIO the 2-node minimum for erasure coding, replacing the single dev instance.
- `smtp-monitor` splits Prometheus/Grafana out from the dev setup's combined infra VM.

**Verifying provisioned machines against this spec:** requires SSH access. Do not use plaintext/shared passwords for this (including any password provided via a spreadsheet or similar) — set up key-based auth the same way it was done for the original 4 VMs (a dedicated keypair, public key appended to each machine's `~/.ssh/authorized_keys`) before checking real specs (`lscpu`, `free -h`, `df -h`).

See also [[project-sengrid-postfix-production-plan]] and `MULTI_IP_POOL_PLAN.md` for the software-side design this hardware supports.
