# Multi-IP Sending Pool — Implementation Plan

**Status:** planning doc, nothing below is built yet except where marked ✅.
**Scope:** how we take Postafly from "1 sending IP" to "10–20 sending IPs," starting in dev, with a clean path to production.
**Owner split:** every task below is tagged **[ME]** (I do this directly, with the SSH/DB/code access I already have) or **[YOU]** (needs your action — money, provider account, or a decision only you can make).

---

## 0. Where we actually stand today

I audited the real code and the live DB before writing this, so the plan isn't guesswork. Short version:

**✅ Already built and working (backend only):**
- DB tables `ip_pools` and `ip_pool_members` exist (migration `V15__ip_pools.sql`) — currently **0 rows in both**, in prod.
- A full admin API at `/api/v1/admin/ip-pools/*` (SUPER_ADMIN only) to create pools, add/remove member IPs, and assign a tenant to a dedicated pool. Nobody's calling it yet — it's wired but unused.
- Real routing logic (`IpPoolService.selectMember`) that already runs on every send: **dedicated tenant pool → warmup pool (only for tenants in DAY_1/DAY_4) → marketing/transactional pool by stream** — with round-robin across whichever pool's members.
- The separate, already-working per-*tenant* volume ramp (`WarmupStage`, `RelayWarmupService`) you already have a full playbook for.
- DKIM signing happens in-app per domain, not via OpenDKIM — so we don't need to touch DKIM config when adding IPs, only Postfix + SPF.

**❌ The gaps that matter for this plan:**
1. **No real Postfix multi-IP config exists anywhere** — `smtp-infra/README.md` describes the intended `master.cf` design in prose, but the actual file was never written. Today there is exactly one Postfix listener on smtp-mail, no per-IP binding.
2. **No per-new-IP warmup.** The round-robin in `IpPoolService` treats every active pool member identically the instant it's added. If we register 10 brand-new IPs into a pool today, they'd get an equal share of full-volume traffic on day one — the exact mistake this whole warmup effort exists to avoid. **I need to build this before we add real IPs, not after.**
3. **No frontend UI for pools.** Everything pool-related is API-only right now (curl/Postman). Admin.tsx manages tenant warmup/limits, but has no screen for pools or members.
4. **`outbound_ip` on `IpPoolMember` is metadata only** — the Java app never binds egress to it. The real IP binding happens at the Postfix layer (`smtp_bind_address` per port), and the DB value has to match that by convention, not by any enforced link. Worth being careful about when wiring this up.
5. A few dead readiness checks reference files that don't exist (`relay/postfix/main.cf.template`, `relay/opendkim/...`) and a "static IP / PTR verified" model that only supports one IP for the whole deployment — will need to become per-IP once we have 10-20.

---

## 1. Before I can start Phase 2 (real IPs), I need answers to these

I can build and fully test everything in Phase 1 without knowing this. But I can't touch real networking without it, and per our working rules I won't reconfigure shared infrastructure (Meraki/NAT/firewall) without you explicitly confirming each change anyway.

- [ ] **Where do the 10–20 IPs actually come from?** Same provider/subnet as the current 38.99.2.73 (i.e. can they be added as more 1:1 NAT mappings on the same Meraki setup), or a separate block/provider?
- [ ] **Who can add them to routing** — is that self-service on your side (a panel you have access to), or does it need a support ticket with whoever issued the IPs?
- [ ] **Can you get PTR (reverse DNS) set for each one** — self-service or ticket, same question, since every IP needs a matching PTR record before it can send anything real.
- [ ] **Initial split** — do you want an even split across the 4 pool types (Transactional / Marketing / Warmup / Dedicated), or a specific allocation? My default recommendation is in §3.4 below.
- [ ] **Reserve one IP permanently for domain-onboarding tests** (so a future test like the zealft.com onboarding never risks the main sending reputation)? I'd recommend yes.

You don't need to answer these to let me start Phase 1 — only before Phase 2.

---

## 2. Division of labor

### [ME] — I'll do these directly

- Fix the warmup gap (§4) — add a real per-IP ramp so a newly added IP starts at a trickle instead of full round-robin share on day one.
- Add DB-level uniqueness so the same IP or `smtp_host:smtp_port` can't be registered twice by mistake (currently unenforced).
- Build a Pools admin page in the frontend (list/create/delete pools, add/remove member IPs, assign a tenant's dedicated pool) — today this only exists as a raw API.
- Write the actual multi-listener `master.cf` (once we know real IPs) — one Postfix `smtpd`/`smtp` transport per pool type, each bound via `smtp_bind_address`, matching `IpPoolMember.smtpHost:smtpPort`.
- Seed the DB via the existing admin API — create the 4 pools, register each IP as a member pointing at its dedicated listener port.
- Update the central SPF record that tenant domains `include:` (the `sengrid.relay.spf-include` target) to authorize the new IPs, so we don't have to touch every tenant domain's SPF individually.
- Clean up the dead readiness checks and make the "static IP / PTR verified" attestations per-IP instead of one global boolean.
- All of Phase 1 (§3.1) end-to-end in dev, without touching real DNS/NAT at all.

### [YOU] — only you can do these

- Confirm routing for the real IPs (§1) — this is a provider/account action, and even where I could technically touch it, network/NAT changes are exactly the kind of shared-infrastructure change I'll always ask you to confirm first.
- Get PTR records set for each real IP with whoever issued them.
- Answer the checklist in §1 so Phase 2 can start with the right numbers.
- Give the go-ahead to actually flip production traffic onto the new pool once it's warmed (Phase 3) — that's a real production risk decision, not a technical one.

---

## 3. Staged rollout

### 3.1 — Phase 1: build and prove it in dev (no real IPs needed yet)

Since this is dev right now, I don't need real internet-routable IPs to build and test the plumbing:

1. Add 10–20 private-range loopback aliases on the dev box (e.g. `127.0.0.2`–`127.0.0.21`) purely for local testing.
2. Point local Postfix/Mailpit-equivalent listeners at each alias so `IpPoolMember.smtpHost/smtpPort` actually resolves to something real.
3. Seed 4 pools via the existing admin API, register the fake IPs as members split across them.
4. Build and test the per-IP warmup throttle (§4) against this fake pool — verify a freshly-added member really does start slow and ramp up.
5. Build the frontend Pools admin page against this same fake data.
6. Verify DB uniqueness constraints reject duplicate IP/host:port registration.

Nothing here touches real DNS, NAT, or the production sending path — fully reversible, safe to iterate on.

### 3.2 — Phase 2: attach the real IPs

Once you've confirmed §1:

1. [ME] Add each real IP as a private alias on smtp-mail's NIC (or wherever routing puts them).
2. [ME] Write the real `master.cf` blocks, one per IP/pool.
3. [YOU] Confirm PTR is live for each IP (I'll verify with `dig -x`).
4. [ME] Register each real IP in the right pool via the (now-built) Pools admin page.
5. [ME] Update the central SPF-include record to list the new IPs.
6. [ME] Turn on the per-IP warmup throttle for these members — nothing sends at full volume until it's earned it, same philosophy as the tenant-level playbook.
7. Monitor exactly like Stage 4 of the deliverability playbook (Postmaster Tools, SNDS, bounce/complaint rate) — per IP this time, not just per tenant.

### 3.3 — Phase 3: production cutover

- Only after each new IP has independently cleared its own warmup ramp (§4) with clean bounce/complaint rates.
- Keep at least one pool member permanently reserved for domain-onboarding tests (per §1's checklist item), isolated from the main sending pools.
- This phase needs your explicit go-ahead — it's a real production risk decision, not something I'll do unprompted.

### 3.4 — Default pool split (my recommendation, pending your answer to §1)

| Pool type | Suggested IP count (of ~15) | Why |
|---|---|---|
| TRANSACTIONAL | 6 | Highest priority, lowest risk traffic — protect this first |
| MARKETING | 4 | Carries the most reputation risk; isolating it protects transactional |
| WARMUP | 2 | Dedicated slow-ramp lane for brand-new tenants (DAY_1/DAY_4) |
| DEDICATED | 3 | Reserve pool for high-volume tenants and onboarding tests, assigned per-org as needed |

---

## 4. The real code gap: per-IP warmup (needs to exist before Phase 2)

Today, `IpPoolService.roundRobin` gives every active member in a pool an equal share of traffic starting the instant it's added — there is zero ramp-up for a *newly added IP*, only for tenants. Adding 10-20 fresh IPs into existing pools today would send them full volume on day one, which defeats the entire point of this exercise.

**Proposed fix** (I'll build this in Phase 1, test it in fake dev pools, before any real IP touches it):

1. Add `added_at` (timestamp) to `ip_pool_members` — already effectively `created_at`, so this may just mean *using* the existing column.
2. In `IpPoolService.selectMember`, instead of pure round-robin, weight each member's selection probability by age-since-`created_at`, using stage bands that mirror the existing tenant `WarmupStage` philosophy:
   - Days 0–3: eligible for a small fixed fraction of that pool's traffic (e.g. capped at 5–10 messages/hour regardless of pool size)
   - Days 4–10: fraction increases
   - Days 11–21: near full share
   - Day 21+: full round-robin weight, same as any established member
3. Enforce this the same place `RelayPolicyService` already enforces tenant-level caps — a pre-send gate, not just a selection-weight nudge, so a burst can't blow past the new IP's daily cap even if it's the only eligible member.
4. Surface each member's current ramp stage/age on the new Pools admin page so it's visible at a glance, not just inferable from `created_at`.

---

## 5. Open questions I'll ask again before executing anything real

These are the same items as §1, repeated here because Phase 2 literally cannot start without them:
1. IP source/subnet + who can route them to smtp-mail
2. PTR self-service or ticket, and with whom
3. Confirmed pool split (or accept my §3.4 default)
4. Reserve a permanent test/dedicated IP — yes/no

---

## 6. Suggested next step

Tell me to start **Phase 1** and I'll begin building the per-IP warmup throttle, the DB uniqueness constraint, and the Pools admin frontend page — all in dev, all reversible, all testable before a single real IP or DNS record is touched.
