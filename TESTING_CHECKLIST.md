# Postafly — Feature Testing Checklist

Work top to bottom. Steps 1–7 prove the core pipeline end to end; 8+ covers everything else.
Tested against the current test environment (postafly.pk, 4-VM setup).

---

## Core pipeline (do these first, in order)

- [ ] **1. Get into an account**
  Register at postafly.pk, or log in. Locked out? Use **Forgot password?** on the login page →
  check inbox (**including Spam** — the domain is still new/unwarmed) → click the newest link only.
  Older reset links stop working as soon as a newer one is requested.

- [ ] **2. Add + verify your domain**
  **Domains** → add domain → publish the 5 DNS records it shows (ownership TXT, SPF, DKIM, DMARC,
  tracking CNAME) at your DNS host → **Recheck DNS** until it says VERIFIED.
  *If the domain already has an SPF or DMARC record, merge into it — don't replace it.*

- [ ] **3. Add + verify sender(s)**
  **Senders** → enter the exact From address + display name → **Add sender** → click **Verify**.
  Do this for *every* address you'll send from. An unverified sender makes sends fail silently
  (status `DROPPED`, no visible error). Trash icon deletes a sender.

- [ ] **4. Send one test email**
  **Send Email** → verified From address, a real recipient, subject, body → Send.

- [ ] **5. Check it landed**
  **Activity** → confirm the message status.
  Then open the email in the recipient's inbox → "Show original" (Gmail) → confirm
  `dkim=pass`, `spf=pass`, `dmarc=pass`.

- [ ] **6. Build a template**
  **Templates** → **Design** tab for the visual editor (fonts, headings, colors, alignment, lists,
  links, images, tables, dividers, CTA buttons) or **HTML** tab to write/paste raw HTML with a
  live **Preview** → Save.

- [ ] **7. Add contacts**
  **Contacts** → **Download sample** → fill it in → **Choose file** → review the loaded rows →
  **Import**. Or **Add manually** for one-offs. Trash icon deletes a contact.
  *Careful with Excel: it mangles long phone numbers into `9.2E+11`. Format the column as Text.*

---

## Campaigns and reporting

- [ ] **8. Group your audience**
  **Lists** = manually chosen contacts. **Segments** = automatic rule (field + operator + value,
  e.g. `tags contains pro`) that stays current as contact data changes.

- [ ] **9. Send a campaign**
  **Campaigns** → verified From address + saved template + audience (list / segment / all) → send.
  New accounts start on low daily caps that ramp up automatically over ~3 weeks — throttling here
  is expected, not a bug.

- [ ] **10. Review results**
  **Analytics** (aggregate charts) · **Activity** (per-message timeline) ·
  **Suppressions** (bounced / complained / unsubscribed — auto-skipped on future sends).

---

## Everything else (as needed)

- [ ] **API Keys** — only if sending via API/code instead of the dashboard.
- [ ] **Webhooks** — push delivery/bounce/open/click events to your own server. Needs a real
      **HTTPS** endpoint (localhost and private IPs are rejected). Signed with
      `X-Postafly-Signature`; retries 5× with backoff.
- [ ] **Billing** — current plan and usage against quotas.
- [ ] **Compliance** — unsubscribe/compliance settings.
- [ ] **Admin** (OWNER/SUPER_ADMIN only) — per-tenant warmup stage, daily/hourly limits,
      suspend/reactivate sending. Check here first if sends are being blocked unexpectedly.

---

## Known gotchas

| Symptom | Cause |
|---|---|
| Send silently fails, status `DROPPED` | From address not added + verified under **Senders** |
| Reset link says "invalid or expired" | A newer reset was requested; only the latest link works |
| Reset email not in inbox | Check **Spam** — postafly.pk is new and not yet warmed up |
| Campaign throttled | Warmup stage caps — intentional, ramps automatically |
| Phone numbers import as `9.2E+11` | Excel auto-converted them; format the CSV column as Text |
