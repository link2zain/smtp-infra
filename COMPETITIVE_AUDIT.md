# Postafly: competitive audit (22 October 2026)

What we measured: our real code (backend, frontend, infrastructure, live servers) against the 53-item checklist from the
ChatGPT plan, and against what SendGrid, Mailgun, Postmark, Amazon SES and Resend publish about themselves.
Every statement about *our* product comes from reading the code or testing the live system. Statements about competitors
come from their own documentation (links at the end). Where a source was secondary or conflicting, it says so.

---

## 1. The verdict

Of the 53 features in the ChatGPT checklist, we fully have **7**, partly have **17**, and are missing **29**.

That sounds worse than the product is. What we have is a solid, secure sending core: verified domains with SPF/DKIM/DMARC checks,
a signed-mail pipeline, suppression, one-click unsubscribe, warm-up limits, bounce collection, signed webhooks with retries,
roles, audit log, billing limits and a clean console. What we lack is almost entirely **measurement and reporting**: we send
mail well but we can't yet *prove and explain* what happened to it the way SendGrid, Postmark and SES do. That is fixable, and
most of it flows from one piece of work (section 5).

The honest way to say it: **we are a working sending platform; we are not yet a deliverability analytics platform.**

## 2. What the ChatGPT plan got right, and where it is outdated

Right: collect events from your own mail system, parse SMTP responses and bounces, add open pixel and click redirects,
keep PostgreSQL (no Kafka needed yet), design around a `messages` + `email_events` pair, and build in the order
activity feed, statistics, deliverability intelligence, reputation. That is also the right order for us.

Needs correcting:
- **Gmail reputation.** It says Google Postmaster Tools gives domain reputation. Secondary sources say Google *removed* the
  domain and IP reputation dashboards in Postmaster Tools v2 and replaced them with a compliance status view, spam rate,
  authentication results and delivery errors. Plan around those four, not around "reputation". (Verify against Google's
  own page before promising customers anything.)
- **Spam complaints.** There is no general complaint feed. Yahoo (Complaint Feedback Loop) and Microsoft (JMRP) send
  per-message complaint reports to senders who enrol. Gmail sends none; it only shows an aggregate spam rate. So "complaint
  rate" will always be incomplete, and SendGrid says exactly this about its own numbers.
- **"Delivered" is not "inbox".** Correct in the plan, and important: SendGrid's own Deliverability Insights page says
  acceptance does not guarantee inbox placement, its data can lag up to 48 hours, and mail a provider accepts and then
  silently deletes leaves no trace.

## 3. The 53-item scoreboard

Legend: HAVE / PARTLY / MISSING, with the evidence.

### 3.1 Core email metrics (1 HAVE, 5 PARTLY, 2 MISSING)
1. Processed / requested / accepted: **HAVE** (the `queued` and `processing` events, total counts).
2. Delivered and delivery rate: **PARTLY, and misleading.** There is no `delivered` event. Our "SENT" status means our own
   Postfix accepted the message, not that the recipient's server did. The dashboard's "delivery rate" is therefore
   "accepted by our relay", which is almost always 100%.
3. Hard and soft bounce rates: **PARTLY.** Bounces are collected (tested today with a synthetic bounce) and classified only
   as HARD or SOFT; the dashboard shows one combined bounce rate.
4. Blocked, deferred, dropped: **PARTLY.** `dropped` works (unverified sender, suppressed address). `deferred` only fires when
   our own hand-off to Postfix fails, never for a remote server saying "try later". There is no `blocked`.
5. Spam complaint count and rate: **PARTLY.** The code that parses feedback-loop mail exists, but we are not enrolled with
   any provider, so in practice nothing arrives.
6. Unsubscribe and suppression metrics: **PARTLY.** Suppressions are listed by type. Unsubscribes are not counted on the
   dashboard and do not create an event or a webhook.
7. Unique opens and clicks: **MISSING.** Every pixel request or click is counted again; the open rate is total opens divided
   by sent and can exceed 100%.
8. SMTP response codes and reasons: **MISSING** as data. Reasons exist only as free text inside `details`; there is no code
   column, no enhanced status (5.7.1), no remote response for successful deliveries.

### 3.2 Message-level investigation (1 HAVE, 3 PARTLY, 2 MISSING)
1. Search by recipient, sender, subject, message ID: **MISSING.** The API returns the latest 50 messages, nothing else.
2. Full event timeline per message: **HAVE** (Activity page).
3. Raw SMTP response and diagnostics: **PARTLY.** Bounce reports keep Status, Action and Diagnostic-Code lines; deliveries keep nothing.
4. Search by date, domain, status, campaign: **MISSING.**
5. CSV export and API event retrieval: **PARTLY.** Per-message events over the API; no event export (contacts export exists).
6. Webhook replay and duplicate protection: **PARTLY.** Automatic retries (5 attempts: 1, 5, 15, 60 minutes), manual retry per
   delivery, and a unique `eventId` for de-duplication. No bulk replay, and the signature has no timestamp (see 4.4).

### 3.3 Reporting and segmentation (0 HAVE, 2 PARTLY, 5 MISSING)
1. Hourly, daily, weekly, monthly reports: **MISSING.** One fixed view: last 14 days, daily.
2. Campaign and category comparison: **PARTLY.** Each campaign has its own numbers; there are no categories and no side-by-side view.
3. Subaccount, project, API-key comparison: **MISSING.** Messages do not record which API key sent them; there are no subusers.
4. Mailbox-provider comparison: **PARTLY.** Top 8 recipient domains by count only, with no per-provider rates.
5. Geography, device, browser, email client: **MISSING.** Opens and clicks do not store IP or user agent.
6. Custom metadata and tags: **MISSING.** The send API has no categories or custom arguments.
7. Custom date ranges and saved reports: **MISSING.**

### 3.4 Deliverability and reputation (1 HAVE, 2 PARTLY, 5 MISSING)
1. SPF, DKIM, DMARC checks: **HAVE** at set-up, plus a manual re-check button. (No continuous monitoring: see 3.6.)
2. Domain and IP reputation signals: **MISSING.**
3. Provider-specific failure analysis: **MISSING.**
4. Bounce and block reason classification: **PARTLY** (HARD / SOFT only; SendGrid has 7 categories, Postmark has 22 types).
5. Complaint monitoring and suppression: **PARTLY.** Suppression on complaint is automatic; there is no incoming feed yet.
6. Blocklist monitoring: **MISSING** (I checked our three IPs by hand today; nothing does it continuously).
7. Gmail Postmaster Tools integration: **MISSING.**
8. Deliverability trend analysis: **MISSING.**

### 3.5 Engagement and campaigns (1 HAVE, 1 PARTLY, 6 MISSING)
1. Open and click tracking: **HAVE** (pixel and redirect), but always on: no per-message or per-account switch.
2. Unique recipient engagement: **MISSING.**
3. Link-level click performance: **MISSING.** The clicked URL is stored in the event, but no report uses it.
4. Unsubscribe tracking: **PARTLY** (works, but as a suppression row, not an event).
5. Campaign conversion attribution: **MISSING.**
6. UTM and website analytics: **MISSING** (SendGrid appends UTM parameters automatically).
7. Bot and security-scanner click filtering: **MISSING.** The same gap hides Apple Mail Privacy Protection "opens".
8. Privacy-aware engagement reporting: **MISSING** (no machine-open flag, no filtered versus raw counts).

### 3.6 Proactive intelligence (0 HAVE, 1 PARTLY, 7 MISSING)
1. Custom alerts and thresholds: **MISSING.**
2. Anomaly detection: **MISSING.**
3. Delivery-latency monitoring: **MISSING.** (`sent_at` minus `created_at` is queue time, not delivery time.)
4. Bounce and complaint spike alerts: **MISSING** for customers. Behind the scenes the hourly warm-up job already promotes or
   suspends a tenant on bounce and complaint thresholds, which protects us but tells the customer nothing.
5. Automated root-cause investigation: **MISSING.**
6. AI-generated weekly reports: **MISSING.**
7. Recommended fixes: **PARTLY.** The Domains page tells people exactly which DNS records to fix; nothing does this for delivery problems.
8. Incident history and recovery tracking: **MISSING.**

### 3.7 Platform and enterprise (3 HAVE, 3 PARTLY, 2 MISSING)
1. Sending volume and quota usage: **HAVE** (Billing page).
2. API success and error rates: **MISSING.**
3. Queue depth and delivery latency: **PARTLY** (admin Relay health shows queued and deferred counts, no latency).
4. Throughput and throttling: **PARTLY.** Warm-up stage limits are enforced per hour and per day; a customer who hits one only gets an error.
5. Usage and cost by customer: **PARTLY** (admin subscriptions and overrides; no cost report).
6. Retention controls and historical exports: **MISSING.** Events are kept forever and cannot be exported.
7. Role-based access and audit logs: **HAVE.**
8. Tenant-level analytics and data isolation: **HAVE.**

## 4. Beyond the checklist: what the competitors have that we don't

The ChatGPT checklist only covers analytics. These are the other things buyers compare.

### 4.1 The send API (compared with SendGrid's published Mail Send limits)
Ours accepts one recipient, one subject, one HTML and one text body, and a stream. SendGrid accepts up to 1,000
personalizations per request, cc, bcc and reply-to lists, attachments, up to 10 categories, 10 KB of custom arguments that
come back in every webhook, scheduled sending up to 72 hours ahead, a batch id to cancel a scheduled batch, a chosen IP pool,
tracking switches (clicks, opens, subscription link, Google Analytics UTM), a sandbox mode, custom headers, and sending by
template id with dynamic data. We have none of these in the API.
- Our templates (simple `{{variable}}` substitution, versioned) can be sent only from campaigns or as a test. An API user
  cannot say "send template X with this data" (this matters: it is how most developers expect to use an email API).
- No idempotency key, so a retried request can send the same email twice. Resend has idempotency keys.
- No rate limiting on `/mail/send` (only login and contact-form endpoints are limited).

### 4.2 Things every serious competitor offers that we lack
- **SMTP relay with API-key login** (port 587/465). Required by WordPress and most off-the-shelf software. Not built.
- **Inbound email** (SendGrid Inbound Parse, Mailgun Routes, Postmark and Resend inbound). Not built.
- **Email validation** (SendGrid, Mailgun). Not built.
- **Subusers or sub-accounts** (SendGrid) and per-project separation. Not built.
- **Teammate security**: two-factor login, single sign-on, IP access restrictions. None exist; accounts rely on a password.
- **Unsubscribe groups with a preference page.** We have suppression groups in the database, but a suppression blocks all
  mail to that address; groups are not honoured as separate lists, and the unsubscribe page is a single yes/no.
- **Marketing suite**: drag-and-drop editor, A/B tests, automations, signup forms. We have a rich-text editor, campaigns
  and scheduling only.
- **Payments.** No checkout or invoicing exists; plans are switched by an admin.
- **Customer-managed dedicated IPs.** Pools exist but only an administrator can create and assign them.

### 4.3 What the leaders are known for (verified)
- **SendGrid:** activity feed with 12 event types and filters by API key, category, template, IP and teammate; statistics by
  category, subuser, mailbox provider, geography, device, browser; 13 months of category statistics; signed webhooks.
- **Postmark:** 22 bounce types; webhooks for delivery, bounce, spam complaint, open, click and subscription change; retries
  at 1, 5, 10, 10, 10, 15 minutes; 45 days of message history.
- **Resend:** about a dozen email events (sent, delivered, delivery_delayed, bounced, complained, opened, clicked, failed,
  scheduled, suppressed, received), webhooks de-duplicated by a delivery id, domain and contact events.
- **Amazon SES:** Virtual Deliverability Manager with dashboards by account, mailbox provider, sending identity and
  configuration set, an advisor with fixes, 30 days of per-message history and 60 days of metrics.
- **Mailgun:** a logs API, alerts on sending metrics, inbox-placement testing with seed lists, email validation, routes for
  inbound mail, IP warm-up plans, send-time optimisation.

### 4.4 Webhook details where we trail
- SendGrid signs every request with an ECDSA key and sends a timestamp header, so a captured request cannot be replayed
  later. Ours signs the body with a shared secret but sends no timestamp. (Postmark has no signing at all and Resend uses a
  timestamped signature, so ours is middle of the pack.)
- Ours has no event filter (every endpoint gets every event), no batching, and the payload lacks SMTP code, response,
  category, custom data, IP, user agent and a machine-open flag.

## 5. The single most important fix: real delivery events from Postfix logs

Today our app hands each message to Postfix and records `sent`. Everything after that, Postfix connecting to Gmail or Outlook
and being accepted, delayed or refused, is invisible to the app unless a bounce email later arrives. This one gap is why there
is no Delivered, no remote Deferred, no Blocked, no SMTP codes, no delivery latency and no provider-by-provider analysis.

**The good news: the data is already on the mail servers, and as of today it joins up cleanly.** I read real log lines from
`smtp-mail-1`. For one message Postfix logs, in order: the queue id, our `Message-ID`, the envelope sender, then the delivery
line with the receiving server, delay, DSN code and the full remote response, e.g. `to=<...>, relay=mail.yasaardata.com[...]:25,
delay=2.2, dsn=2.0.0, status=sent (250 OK ...)`. Customer mail now leaves with the envelope sender
`bounce+<our message id>@bounces.postafly.com.pk` (changed earlier today), so every delivery line can be matched to our
message directly.

**Design (small, no new heavy software):**
1. A tiny shipper on each of the 3 mail servers follows `/var/log/mail.log`, groups lines by queue id, and POSTs finished
   delivery attempts to a new authenticated endpoint on the backend (batched, retried, with a shared secret).
2. The backend turns each into an event: `delivered` (status=sent), `deferred` (status=deferred, with attempt number and the
   remote reason), `bounced` (status=bounced, for immediate rejections), storing SMTP code, enhanced status, remote server,
   provider, TLS and delay in new columns (not buried in text).
3. The dashboard's delivery rate becomes accepted-by-recipient divided by eligible messages, and "Sent" is renamed
   "Accepted by our relay".
4. Turn on Postfix TLS logging so we can report whether each delivery was encrypted.

Unlocked by this alone: Delivered, remote Deferred, Blocked, SMTP code and reason, raw response, delivery latency,
provider-specific failure analysis, bounce and block classification inputs, throttling visibility: roughly a dozen checklist items.

## 6. Things that are misleading today (fix or reword first)

1. **"Delivery rate"** on the dashboard (see 3.1.2). It must not stay as is once we compare ourselves to anyone.
2. **Link tracking on your own domain.** The Domains page shows a `track.<your domain>` CNAME and says it is "used for click
   tracking on your own domain". The code never uses it: tracking links always point at `postafly.com.pk`. Either build it
   (a branded tracking domain is a standard SendGrid and Mailgun feature, and helps deliverability) or remove the claim.
3. **Open rate** can exceed 100% because opens are not unique.
4. **Complaint rate** looks authoritative but has no source feeding it.
5. **Warm-up limits vs "unlimited" Free plan.** The Free plan is unlimited, but each new account starts at warm-up stage
   DAY_1: 500 transactional and 100 marketing mails per day, 50 and 10 per hour. That is deliberate protection, but a
   customer sees only an error. Show it, with the current stage and when it lifts.
6. **Suppression groups** exist but do not behave like groups (see 4.2).

**Status on 22 October 2026 (all six fixed in Phase A):**
1. Delivery rate: counts real delivered/bounced/blocked results from the mail servers (A1).
2. Link tracking domain: the claim and the `track.` CNAME were **removed** (A4). Links use postafly.com.pk and are signed (A2). A branded link
   domain would need automatic TLS for every customer domain (for example Caddy with on-demand certificates), which is a separate project.
3. Open rate: unique opens, never above 100%, with Apple pre-loads and scanners separated (A2).
4. Complaint rate: shows "Not measured yet" until a feedback loop is connected (A4).
5. Warm-up limits: shown on the Dashboard and Send page with usage and when they lift; the "limit reached" error now explains itself (A4).
6. Suppression groups now behave as lists: an unsubscribe stops marketing for that list (or all marketing), never transactional mail; bounces
   and complaints still stop everything; the unsubscribe page offers the choice (A4).
Also fixed in A4: the pricing page now reads the real plan limits (it showed outdated Free and Growth numbers); the plain-text part of marketing
mail now carries the postal address and unsubscribe link; the admin plan editor can set picture storage.

## 7. Industry requirements (Gmail, Yahoo, Microsoft)

For bulk senders (the commonly cited line is 5,000+ messages a day to one provider's consumers) all three now require
authentication aligned with the visible From domain, DMARC, one-click unsubscribe on marketing mail, valid forward and reverse DNS,
and complaint rates under 0.3% (aim for 0.1%). Microsoft began rejecting non-compliant bulk mail on 5 May 2025 per
secondary sources; Gmail and Yahoo use permanent 5.7.x rejections.

Where we stand: SPF, DKIM and DMARC guidance and checks **done**; DKIM signing **done** (customers' and our own);
reverse DNS and matching hostnames **done**; one-click unsubscribe headers **done for marketing mail**; TLS for sending
**opportunistic** (self-signed certificate on our receiving side, fine for now); complaint rate under 0.3%: **cannot be
measured yet** (needs Postmaster Tools and the Yahoo and Microsoft feeds, section 9); an aligned DMARC policy for customers:
we publish `p=none` suggestions only.

## 8. Recommended roadmap

Positioning advice: the realistic target is **Postmark and Resend level for developers, plus a deliverability analytics and AI
layer that most of them lack**. SendGrid and Mailgun are decade-old suites; matching their marketing automation is a later
question. All sizes below are my build effort, not counting waiting for outside approvals.

**Phase A: make the numbers true (do first, about 1 to 1.5 weeks)**
1. Postfix delivery events (section 5): shipper, endpoint, new event columns, corrected delivery rate. *Large.*
2. Unique opens and clicks, with IP and user agent captured to derive country, device, email client and a machine-open flag
   for Apple Mail Privacy Protection and security scanners; raw and filtered counts side by side. *Medium.*
3. Send API: categories, custom args (returned in webhooks), reply-to, cc and bcc, attachments, several recipients per
   request, scheduled send, send by template id with data, idempotency key, tracking switches, rate limiting, and
   recording the API key on each message. *Large, but each piece is small.*
4. Webhooks: pick events per endpoint, timestamp in the signature, richer payload, `delivered` and `unsubscribed` events. *Small.*
5. Fix the misleading items in section 6, including either building or removing the branded tracking domain. *Small to medium.*

**Phase B: activity and statistics (about 1 week)**
Searchable, paged Activity with filters and CSV export; statistics with date range, hour/day/week/month grouping and filters
by category, stream, campaign, API key and provider; provider and category comparison with rates; saved views; an events API
with pagination. *Medium.*

**Status on 28 October 2026 (Phase B built and live):** the Activity page searches and pages through all mail (date range, status, type,
category, API key, campaign, provider, domain, source, engagement, free text) with CSV export and named saved views; the new Reports page
has hour, day, week and month charts on the viewer's clock, nine totals with rates, and side-by-side comparison by provider, domain,
category, API key, campaign, type and source, with CSV. Scoreboard items now HAVE: 3.2.4 (search), 3.2.5 (events search with paging and CSV),
3.3.1 (hourly to monthly), 3.3.2 (campaign and category comparison), 3.3.3 (API-key comparison; there are still no subusers),
3.3.4 (provider comparison with rates, by recipient domain only, not by MX host) and 3.3.7 (custom ranges, saved views).
Still PARTLY: 3.3.6 (categories filter and compare, custom arguments do not). Not done in Phase B:
- The new endpoints answer to console sign-in only. An API key cannot read them, on purpose: today every key can send, and a key that
  could also read activity would expose recipients. Developer access needs scope-aware keys (a read scope separate from `mail:send`).
  Note the older `/api/v1/dashboard/overview` already answers to any send key and returns the last 12 events with recipient addresses.
- Country, device and email-client breakdowns are stored since A2 but are not yet a report dimension.
- Reports use the sent date; there is no "by event date" view.
Checked against real PostgreSQL with 300 seeded messages (every total equals an independent SQL count); API reference in the backend repo,
`docs/REPORTING_API.md`. Migration V35 adds `saved_views` and an index on `(organization_id, created_at)`.

**Phase C: deliverability intelligence (about 1.5 weeks)**
SMTP error classification (SendGrid-style categories plus Gmail and Outlook specific rules); daily domain health checks
(SPF, DKIM, DMARC, reverse DNS, TLS) with alerts when something breaks; blocklist monitoring; alerts and anomaly detection
for bounce, complaint and deferral spikes (email and webhook), per-customer baselines; incident history; DMARC aggregate
report ingestion; Gmail Postmaster v2 connection; Microsoft and Yahoo feedback programmes feeding complaints. *Large.*

**Phase D: differentiators and parity (after launch, in this order)**
AI deliverability analyst and weekly report; inbox-placement testing from our own seed mailboxes; pre-send spam score;
email validation; SMTP relay (587) with API-key login; two-factor login; unsubscribe groups with a preference page; inbound
parse; payments; subusers; template editor upgrade and A/B tests. *Each Medium to Large.*

## 9. What to install and what to sign up for

Everything below is free unless marked. "You" means an action only the account owner can take.

**Sign-ups (free)**
1. **Google Postmaster Tools** (you): add `postafly.com.pk` (a DNS TXT record I can add in Cloudflare) and later each customer
   domain they own. For the API connection, a Google Cloud project with an OAuth client is needed (free). Unconfirmed:
   whether Google requires an app-verification review for the Postmaster scope; I will check Google's current page before building.
2. **Microsoft SNDS and JMRP** (you): free; JMRP needs dedicated IPs, which our three are. SNDS proves ownership by emailing
   the contact in the IP's registry record, which is probably Trubyte, so **we will likely need Trubyte's help once**.
3. **Yahoo Sender Hub, Complaint Feedback Loop** (you): free, per domain; requires DKIM-signed mail where the signing domain
   is the From domain (customer domains qualify once signed), and a monitored address for the reports.
4. **Spamhaus Data Query Service key** (you): free within fair use, by email sign-up. Spamhaus blocks queries from public
   resolvers like Google and Cloudflare, so we also install our own DNS resolver (below).
5. **MaxMind GeoLite2** (you): free account and licence key, attribution required; or DB-IP Lite, which needs no account.
   Used for country and city from the recipient's IP on opens and clicks.
6. **Seed mailboxes** (you): a few free accounts at Gmail, Outlook, Yahoo and iCloud, for our own inbox-placement test
   (phone verification may be needed). Optional paid alternative: GlockApps (pricing varies by source, roughly tens of
   dollars a month); verify on their site.
7. **Anthropic API key** (you; **paid, pay per use**): for the AI deliverability analyst. Set a monthly spend limit when you
   create the key. Cost stays small because analysis runs on summaries of a customer's own events.

**Install on our servers (free, I do these)**
- A small log shipper (a few dozen lines of Python, or Vector) on the 3 mail servers.
- `unbound`, a local DNS resolver, for blocklist lookups.
- SpamAssassin or Rspamd on one mail server, for pre-send spam scoring (Rspamd speaks HTTP, which suits an API).
- Optional: `parsedmarc` (open source) to read DMARC reports, though a small built-in parser is also reasonable.
- Prometheus and Grafana already exist on the monitor server and can chart platform health from the app's metrics endpoint.

**Good to have (free tiers)**
- An uptime monitor with a public status page (UptimeRobot or Better Stack) and error tracking (Sentry) for the app.

**Possible later spends (all optional)**
- An email-validation vendor if we want deep checks (ZeroBounce, Kickbox), a managed inbox-placement tool, and a payment
  provider when plans start charging (which one depends on where customers pay from; I will ask when we get there).

## 10. Sources

SendGrid / Twilio:
- Statistics: https://www.twilio.com/docs/sendgrid/ui/analytics-and-reporting/stats-overview
- Email Activity Feed: https://www.twilio.com/docs/sendgrid/ui/analytics-and-reporting/email-activity-feed
- Event Webhook events and fields: https://www.twilio.com/docs/sendgrid/for-developers/tracking-events/event
- Webhook security: https://www.twilio.com/docs/sendgrid/for-developers/tracking-events/getting-started-event-webhook-security-features
- Deliverability Insights: https://www.twilio.com/docs/sendgrid/ui/analytics-and-reporting/deliverability-insights
- Mail Send API: https://www.twilio.com/docs/sendgrid/api-reference/mail-send/mail-send

Others:
- Postmark bounces: https://postmarkapp.com/developer/api/bounce-api and webhooks: https://postmarkapp.com/developer/webhooks/webhooks-overview
- Resend event types: https://resend.com/docs/dashboard/webhooks/event-types
- Amazon SES Virtual Deliverability Manager: https://docs.aws.amazon.com/ses/latest/dg/vdm.html
- Mailgun features: https://www.mailgun.com/features/ and control panel: https://help.mailgun.com/hc/en-us/articles/360021388013-The-Mailgun-Control-Panel

Industry and tools:
- Postmaster Tools v2 (secondary): https://folderly.com/blog/google-postmaster-tools-v2-migration-guide-2025 and Google: https://support.google.com/mail/answer/14668346
- Yahoo Complaint Feedback Loop: https://senders.yahooinc.com/complaint-feedback-loop
- Microsoft SNDS and JMRP (secondary): https://docs.inboxally.com/provider-deliverability-guides/microsoft-complaint-feedback-programs-jmrp-and-snds
- Spamhaus DQS: https://www.spamhaus.com/faqs/data-query-service/
- Apple Mail Privacy Protection: https://bird.com/en-us/docs/knowledge-base/deliverability/apple-mail-privacy
- parsedmarc: https://pypi.org/project/parsedmarc/
- Rspamd: https://docs.rspamd.com/tutorials/migrate_sa
