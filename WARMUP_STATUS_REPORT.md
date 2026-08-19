# Postafly Warmup & Deliverability — Full Report

**Date:** 2026-08-18
**Domain:** postafly.pk (migrated from postafly.com)
**Sending IP:** 38.99.2.73 (smtp-mail)

---

## 1. Current infrastructure status

| Item | Status |
|---|---|
| Domain | `postafly.pk` — fully live, replacing the retired `postafly.com` |
| App server | `38.99.2.71` — serving `https://postafly.pk`, valid Let's Encrypt cert (`CN=postafly.pk`) |
| Mail server | `38.99.2.73` (smtp-mail, Postfix) — only sending IP, shared by all tenants |
| SPF (postafly.pk) | `v=spf1 ip4:38.99.2.73 ~all` — published, correct (lists only the real sending IP) |
| DMARC (postafly.pk) | `v=DMARC1; p=none; rua=mailto:dmarc@postafly.pk` — monitor-only, as expected for a new domain |
| MX (postafly.pk) | `mail.postafly.pk`, priority 10 |
| PTR (38.99.2.73) | Fixed — now resolves to `mail.postafly.pk`, which forward-resolves back to `38.99.2.73` (forward-confirmed rDNS restored) |
| postafly.pk own DKIM | Not yet added — optional, only needed if you want to send test/demo mail from an `@postafly.pk` address through the app itself |
| Google Postmaster Tools | Not yet registered |
| Microsoft SNDS | Not yet registered |
| Multi-IP pool | Designed (see `MULTI_IP_POOL_PLAN.md`), not yet built — still 1 sending IP total |

**Known gap carried over from the old setup:** postafly.com's DNS was found broken during the migration (root A record pointed to an unrelated IP, serving a directory listing, not the app) — postafly.pk was built correctly from scratch to avoid repeating it (dedicated `mail.` subdomain, exact-IP SPF instead of `+a`/`+mx`).

---

## 2. Stage 0 — Foundation (technical prerequisites)

Nothing below matters if these aren't true first. Mailbox providers check these mechanically, before your message content is even considered.

### 2.1 Authentication (done for postafly.pk)
- **SPF** — done, lists the real sending IP directly.
- **DKIM** — generated automatically per domain from the Domains dashboard (2048-bit RSA, selector `sgr1`). Not yet generated for postafly.pk's own root domain (optional — see §1).
- **DMARC** — done, currently `p=none` (monitor-only). See §2.3 for the enforcement ramp.
- **PTR / reverse DNS** — done and fixed as of this report.

### 2.2 Mailbox hygiene addresses (RFC 2142)
Set up and monitor on postafly.pk and every customer domain that sends through it:
- `postmaster@` — required by RFC 5321; providers may email it about delivery problems.
- `abuse@` — required for bulk senders; spam-complaint escalations land here.
- `dmarc@` — DMARC aggregate reports are already configured to go here; if the mailbox doesn't exist, reports bounce and you lose visibility.

### 2.3 Bulk sender requirements (Google & Yahoo, enforced since Feb 2024)
If 5,000+ messages/day go to Gmail or Yahoo addresses, these are not optional:
- SPF **and** DKIM both passing (not either/or).
- A DMARC record, at minimum `p=none`.
- One-click unsubscribe via `List-Unsubscribe` / `List-Unsubscribe-Post` headers (RFC 8058) on marketing sends, honored within 2 days.
- Spam-complaint rate under 0.3% (Google Postmaster Tools) — this is the exact threshold Postafly's own auto-suspension is tuned to (§3).

Volume today is far below the 5,000/day threshold, so not urgent yet — but add the List-Unsubscribe header before marketing volume ramps into WEEK_2/STABLE tiers, not after.

### 2.4 DMARC policy ramp
| Policy | Meaning | Move to it when… |
|---|---|---|
| `p=none` | Monitor only | Default today — keep until you've read a few weeks of aggregate reports |
| `p=quarantine` | Failing mail goes to spam | Reports show ~100% of legitimate volume passing SPF/DKIM alignment |
| `p=reject` | Failing mail is rejected outright | After a stable stretch at quarantine with no legitimate mail caught |

---

## 3. Stage 1 — Visibility (Google Postmaster Tools & Microsoft SNDS)

Free, ~15 minutes each, and should be done before any real volume increase.

**Google Postmaster Tools** (`postmaster.google.com`):
- Add `postafly.pk` as a domain, verify via TXT record.
- Repeat for each customer domain sending meaningful volume once its Postafly domain authentication is VERIFIED.
- Check weekly: Spam Rate (must stay under 0.3%), Domain/IP reputation (High/Medium/Low/Bad), Feedback loop, Delivery errors.
- If IP reputation ever shows Bad: stop increasing volume immediately — it affects every tenant on the shared IP, not just whoever triggered it.

**Microsoft SNDS** (`sendersupport.olc.protection.outlook.com/snds`):
- Register 38.99.2.73.
- Check for complaint rate, spam-trap hits, filter status.

**Blocklist monitoring**: MXToolbox (`mxtoolbox.com/blacklists.aspx`), Talos (`talosintelligence.com/reputation_center`), and Spamhaus — a single Spamhaus listing is the most consequential to avoid; delisting is slow.

---

## 4. Stage 2 — The automatic warmup ramp (already built into the code)

Runs automatically, per tenant, with zero manual steps — `WarmupStage.java` / `RelayPolicyService.java` / `RelayWarmupService.java`.

### 4.1 The four stages, exact numbers
| Stage | Marketing daily/hourly | Transactional daily/hourly | Per major mailbox/day |
|---|---|---|---|
| DAY_1 | 100 / 10 | 500 / 50 | 50 |
| DAY_4 | 300 / 30 | 1,000 / 100 | 150 |
| WEEK_2 | 1,000 / 100 | 3,000 / 300 | 500 |
| STABLE | 5,000 / 500 | 10,000 / 1,000 | 1,000 |

"Major mailbox" = gmail.com, googlemail.com, yahoo.com, outlook.com, hotmail.com, live.com. Hourly caps exist so a burst can't burn a whole day's allowance at once — providers weight sudden bursts from a cold sender worse than the same volume spread evenly.

### 4.2 How promotion works
A background job runs hourly and promotes a tenant to the next stage only when **all** are true:
- Minimum time in the current stage: 3 days (DAY_1), 7 days (DAY_4), 14 days (WEEK_2).
- Real volume actually sent: cumulative sends since entering the stage ≥ 20% of (stage's transactional daily limit × days in stage). A tenant that sends nothing does not age through stages on the clock alone.
- 24h bounce rate ≤ 2.0% at promotion time.

### 4.3 How auto-suspension works
Checked every hour, even for STABLE tenants:
| Signal | Threshold (24h trailing) | Effect |
|---|---|---|
| Bounce rate | ≥ 5.0% | Sending suspended |
| Complaint rate | ≥ 0.3% | Sending suspended |

0.3% matches Google's own bulk-sender threshold — tuned to trip before Google notices, not after. Suspension is currently silent to the tenant (only shows as sends failing) — worth a dashboard notice as a future improvement.

### 4.4 Where the thresholds live
```
sengrid.relay.warmup.enabled                          (default: true)
sengrid.relay.warmup.promotion-bounce-threshold        (default: 2.0)
sengrid.relay.warmup.suspension-bounce-threshold       (default: 5.0)
sengrid.relay.warmup.suspension-complaint-threshold    (default: 0.3)
sengrid.relay.warmup.cron                              (default: hourly, minute 17)
```

---

## 5. Stage 3 — Feeding the ramp correctly

The engine caps *how much* you can send. It has no opinion on *who* you send it to or *what* it says — and that's what actually determines inbox vs. spam placement.

### 5.1 Recipient selection
- Send to your most-engaged people first: those who've opened/clicked before, or a small, genuine seed list of real, willing testers. Engagement (opens, clicks, replies) is the strongest positive signal providers use.
- Never send cold/purchased/scraped lists during warmup — fastest way to trip the 5.0%/0.3% auto-suspension.
- Spread major-mailbox sends out rather than batching, matching the per-mailbox daily cap above.

### 5.2 List hygiene (ongoing)
- Remove hard bounces immediately via the suppression list.
- Honor unsubscribes/complaints instantly — a delayed unsubscribe causing a second complaint costs more reputation than the one it would have prevented.
- Never re-add a suppressed address without explicit reconfirmation.
- Run a re-permission/sunset pass on old/inactive lists before mailing them at higher volume.

### 5.3 Content practices
- Consistent From name/address — frequent switching reads as evasive.
- Real, working unsubscribe link and real physical address in the footer (CAN-SPAM/GDPR baseline).
- Balanced text-to-image ratio — an email that's one large image with no text is a classic spam pattern.
- Avoid link shorteners and mismatched display-vs-actual links.

---

## 6. Stage 4 — Monitoring & incident response

### 6.1 What to check, how often
| Check | Where | Frequency |
|---|---|---|
| Bounce/complaint rate | Internal relay health endpoint + Postmaster Tools | Daily during active warmup |
| Domain/IP reputation | Google Postmaster Tools | Weekly |
| Spam-trap hits, complaint rate | Microsoft SNDS | Weekly |
| Blocklist status | MXToolbox/Talos | Weekly, or on any bounce spike |
| warmupPausedReason | Relay admin endpoint/DB | Whenever sends fail unexpectedly |

### 6.2 If a tenant gets auto-suspended
1. Check `warmupPausedReason` — bounce or complaint trigger.
2. Find the messages driving the rate — usually a bad import, stale list, or mistyped domain.
3. Fix the root cause before manually un-suspending (un-suspending without fixing it just re-trips on the next hourly check).
4. Clear `sendingSuspended` via the relay admin endpoint once resolved.

### 6.3 If the shared IP itself gets blocklisted
Platform-wide incident — every tenant on 38.99.2.73 is affected. Pause new sends platform-wide, identify and remove the offending tenant/list, request delisting (Spamhaus and most others have a public form), expect hours to a few days. This blast radius is the core argument for §7's multi-IP separation.

---

## 7. Stage 5 — Advanced: scaling past a single shared IP

Everything above works today with one IP. It stops being enough once volume/tenant count grows, since reputation risk is currently pooled across every tenant.

- **Separate IPs by stream, then by risk** — transactional vs. marketing on separate IPs is the highest-leverage change; a dedicated IP per high-volume/high-risk tenant next. Each new IP restarts its own warmup from DAY_1.
- **Subdomain isolation** — send marketing from a distinct subdomain (e.g. a dedicated `mail.` or per-tenant subdomain) rather than the bare root domain, so a marketing reputation problem doesn't touch root-domain/transactional reputation.
- **Tighten DMARC enforcement** as confidence grows (§2.4).
- **Transport-layer signals**: MTA-STS (require/assert TLS for mail transport), TLS-RPT (reporting companion), BIMI (verified brand logo in inbox — requires DMARC at `p=quarantine` or stricter first).
- **Feedback loops (FBLs)** with Yahoo/AOL once volume justifies the registration overhead.

Full implementation plan for the multi-IP piece specifically: `MULTI_IP_POOL_PLAN.md` (found the pool tables/API already exist in code but are unused, and that adding new IPs today would give them full traffic instantly with zero ramp — needs a per-IP warmup mechanism built before any real new IP is attached).

---

## 8. Condensed next-steps checklist

- [ ] Register Google Postmaster Tools for postafly.pk
- [ ] Register Microsoft SNDS for 38.99.2.73
- [ ] Run a baseline blocklist check (MXToolbox) on postafly.pk + 38.99.2.73
- [ ] Confirm postmaster@/abuse@/dmarc@ mailboxes exist and are monitored
- [ ] Add List-Unsubscribe headers to marketing sends before scaling into WEEK_2/STABLE volume
- [ ] Decide if postafly.pk needs its own DKIM entry (only if sending test/demo mail from `@postafly.pk` through the app)
- [ ] Revisit DMARC policy (`p=none` → `p=quarantine`) once aggregate reports look clean
- [ ] Begin Phase 1 of the multi-IP pool plan when ready to scale beyond one IP
