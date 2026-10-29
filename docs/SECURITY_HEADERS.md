# Security headers for the website and API (audit S-03)

The public site used to send none of the usual browser protections and announced its nginx version (`Server: nginx/1.28.3 (Ubuntu)`).
This change adds them. **Nothing here is deployed by merging it:** the VMs only change when `setup.sh` / `enable-https.sh` is
run again, or when the steps under "Rolling it out" are followed by hand.

## What is sent

| Header | Why |
| --- | --- |
| `X-Content-Type-Options: nosniff` | the browser must not guess a file's type |
| `X-Frame-Options: DENY` | nobody can put the console in a frame (clickjacking) |
| `Referrer-Policy: strict-origin-when-cross-origin` | links to other sites carry our address only, not the page or its query |
| `Permissions-Policy` | camera, microphone, location, payment, USB and sensors are switched off; the console uses none |
| `Strict-Transport-Security: max-age=300` | HTTPS only. Starts at five minutes because browsers remember it (see below) |
| `Content-Security-Policy-Report-Only` | which places a page may load from; forbids inline scripts and event handlers |
| `server_tokens off` | the nginx version is no longer shown |

The backend already sends `nosniff` and `X-Frame-Options` on `/api`, `/track` and `/unsubscribe` answers. The snippet hides the
backend's copy (`proxy_hide_header`) so the browser sees exactly one of each.

## Files

- `production-9vm/app/security-headers.conf` — the headers. Installed as `/etc/nginx/snippets/postafly-security-headers.conf`.
- `production-9vm/app/nginx-https.conf.template`, `nginx.conf` and `postafly-com-9vm/website/nginx.conf` — `server_tokens off` and the `include`.
- `setup.sh`, `enable-https.sh` (and the website `setup.sh`) — copy the snippet into place before `nginx -t`.
- `postafly-com-9vm/website/security-headers.conf` — the same snippet for the other environment, kept identical.
- `tests/nginx-security-headers.sh` — the regression test (below).

The picture host (`nginx-img.conf.template`) already sends `nosniff`, a locked-down policy and `server_tokens off`; it is unchanged.

## The content security policy

```
default-src 'self';
script-src  'self' https://accounts.google.com/gsi/client;
style-src   'self' 'unsafe-inline' https://fonts.googleapis.com https://accounts.google.com/gsi/style;
font-src    'self' https://fonts.gstatic.com data:;
img-src     'self' data: blob: https:;
connect-src 'self' https://accounts.google.com/gsi/;
frame-src   https://accounts.google.com/gsi/;
object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'
```

- **Scripts** come only from this site and Google's sign-in script. A script that gets into a page some other way (stored template
  content, for instance) does not run, and neither does an inline `onerror=` or a `javascript:` link. This is the safety net behind the
  editor fix for audit S-01. It does **not** stop an injected `<style>` or frame, so the editor and server fixes are still needed.
- `'unsafe-inline'` is allowed for **styles only**, because React and the email editor set inline `style` attributes.
- `img-src` allows any https picture because the email preview shows whatever pictures a template links to.

It ships in **report-only** mode: the browser lists what it would have blocked in its console and blocks nothing.

### What was checked (2026-10-30, local stack, real Chrome, enforcing mode)

Every console page (21 in all, signed in as the demo owner), the public site with its 3D hero, login and sign-up: **no violations**.
Google's sign-in script and its button frame **load**. (Real sign-in needs the production client id; it was not exercised.)
The old, vulnerable editor behind this policy no longer ran the stored script, though its injected style still hid the page.

Known cost, for the template builder trial only (`/templates/builder-trial`): under the enforcing policy it still loads, previews
and switches devices exactly as before, but the browser refuses **one `eval`** (GrapesJS templates its panels that way) and the
**Font Awesome stylesheet GrapesJS fetches from cdnjs.cloudflare.com**. When the builder becomes a real page: serve the icon
font ourselves (or turn that option off), and decide whether the builder route alone needs `'unsafe-eval'`, with its own
`location` block and a second snippet, rather than loosening the policy for the whole site.

## Rolling it out (by hand, on a VM)

1. Keep a copy: `sudo cp /etc/nginx/sites-available/sengrid /etc/nginx/sites-available/sengrid.before-headers`
2. Install the snippet: `sudo mkdir -p /etc/nginx/snippets && sudo cp security-headers.conf /etc/nginx/snippets/postafly-security-headers.conf`
3. Add the two lines (`server_tokens off;` and the `include`) to the `server` block, or re-run `enable-https.sh`.
4. `sudo nginx -t && sudo systemctl reload nginx`
5. Check: `curl -sI https://postafly.com.pk/` shows the headers and `Server: nginx`.
6. **Report-only for a few days.** Open every page, including "Continue with Google", with the browser console showing. A line that starts
   "[Report Only] Refused to…" is something the policy would block; fix it or allow it, then repeat.
7. **Enforce:** in the snippet, comment out the `Report-Only` line and remove the `#` from the line under it. Test, reload.
8. **Raise HSTS in steps**, each only after the site has worked for a while: `300` → `86400` → `604800` → `2592000` → `31536000`.
   A browser keeps the last value it saw, so a mistake at a high value cannot be undone from the server. `includeSubDomains` and
   `preload` stay off until every name under the domain has been checked.

**Rollback:** `sudo cp /etc/nginx/sites-available/sengrid.before-headers /etc/nginx/sites-available/sengrid && sudo nginx -t && sudo systemctl reload nginx`.
(HSTS already seen by a browser lasts for the `max-age` it was given.)

## The regression test

```bash
tests/nginx-security-headers.sh                       # the live HTTPS template and its snippet
tests/nginx-security-headers.sh <template> <snippet>  # any other pair, for example an older copy to watch it fail
```

It starts the real config in Docker with a stand-in backend that sends the same two headers Spring does, then checks the web page, an
asset path, a proxied API answer, a tracking link, an unsubscribe link and a refusal made by nginx itself: one copy of each header on
every answer, `nosniff` and `DENY`, HSTS with a `max-age` and no `includeSubDomains`/`preload`, no version in `Server`, and a policy
that has the closed-off directives and a `script-src` with no inline code, `eval`, `data:` or wildcard. Nothing leaves the machine.
Against the previous config it fails 54 checks; against this one it passes 73.
