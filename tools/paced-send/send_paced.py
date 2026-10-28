#!/usr/bin/env python3
"""Send a small, paced marketing test through the Postafly send API.

Reads recipient addresses from a spreadsheet (.xlsx, first column) or a .csv/.txt file, rotates through five different marketing
mails, and gives each recipient its own send time, one every --interval minutes. The messages are SCHEDULED on the server
(`sendAt`), so nothing has to stay running on this PC once the run has finished.

Nothing is sent unless you pass --send. Without it the script only prints the plan.

    python send_paced.py "first mails.xlsx" --from john@zmdservice.com                 # plan only
    python send_paced.py "first mails.xlsx" --from john@zmdservice.com --send          # schedule it
    python send_paced.py --cancel                                                      # cancel what is still scheduled

The API key is read from the file `.api-key` next to this script (or the POSTAFLY_API_KEY environment variable). It is never printed.
Every request is logged in `sent_log.csv`; addresses already in the log are skipped, so running the script twice never double-sends.
"""
import argparse
import csv
import datetime as dt
import hashlib
import json
import os
import random
import re
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
LOG_PATH = os.path.join(HERE, "sent_log.csv")
LOG_FIELDS = ["address", "template", "send_at", "http", "status", "message_id", "batch_id", "note"]
EMAIL = re.compile(r"^[A-Za-z0-9._%+'-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$")


def page(title, paragraphs, link_text, link):
    body = "".join(f'<p style="margin:0 0 14px">{p}</p>' for p in paragraphs)
    return (
        '<div style="font-family:Arial,Helvetica,sans-serif;font-size:15px;line-height:1.55;color:#1f2933;max-width:560px">'
        f'<h2 style="font-size:20px;margin:0 0 16px">{title}</h2>{body}'
        f'<p style="margin:18px 0"><a href="{link}" style="color:#1a56db">{link_text}</a></p>'
        '<p style="margin:0">John<br>ZMD Service</p></div>'
    )


TEMPLATES = [
    {
        "key": "welcome",
        "subject": "Welcome to ZMD Service updates",
        "paragraphs": [
            "Hello,",
            "This is John from ZMD Service. You are on our updates list, so every now and then we will send you news, tips and offers.",
            "We keep it short and we only write when there is something worth reading. You can leave the list at any time with the link at the bottom of this email.",
        ],
        "link_text": "Visit our website",
    },
    {
        "key": "product-update",
        "subject": "What is new at ZMD Service this month",
        "paragraphs": [
            "Hello,",
            "A short round-up of what we have been working on: quicker replies to customer questions, clearer pricing, and a simpler first week for new customers.",
            "If one of these matters to you, reply to this email and tell us what you would like to see next. A real person reads every answer.",
        ],
        "link_text": "See the details",
    },
    {
        "key": "newsletter-tips",
        "subject": "Three small habits for a calmer inbox",
        "paragraphs": [
            "Hello,",
            "1. Check your junk folder once a week and mark anything useful as &ldquo;not junk&rdquo;. It teaches your mailbox what you want.",
            "2. Add the senders you trust to your contacts, so their mail always reaches your inbox.",
            "3. Unsubscribe from what you no longer read. A smaller inbox is easier to keep tidy.",
        ],
        "link_text": "Read more tips",
    },
    {
        "key": "event-invite",
        "subject": "Join a short online walkthrough",
        "paragraphs": [
            "Hello,",
            "We are planning a short online walkthrough of how we work, about twenty minutes with time for questions.",
            "If you would like to take part, reply to this email with a day and time that suits you and we will find a slot that works.",
        ],
        "link_text": "Find out more",
    },
    {
        "key": "feedback",
        "subject": "One question, about two minutes",
        "paragraphs": [
            "Hello,",
            "We would like to hear from you. What is the one thing that would make our emails more useful to you?",
            "Just reply with a single line. There is no form and no wrong answer, and your reply goes straight to me.",
        ],
        "link_text": "Tell us more",
    },
]


def render(template, link):
    paragraphs = template["paragraphs"]
    html = page(template["subject"], paragraphs, template["link_text"], link)
    plain = re.sub(r"&ldquo;|&rdquo;", '"', "\n\n".join(paragraphs))
    text = f"{template['subject']}\n\n{plain}\n\n{template['link_text']}: {link}\n\nJohn\nZMD Service"
    return html, text


def read_addresses(path):
    rows = []
    if path.lower().endswith(".xlsx"):
        import openpyxl  # only needed for spreadsheets

        sheet = openpyxl.load_workbook(path, read_only=True, data_only=True).worksheets[0]
        rows = [r[0] for r in sheet.iter_rows(values_only=True) if r and r[0] is not None]
    else:
        with open(path, newline="", encoding="utf-8-sig") as handle:
            rows = [r[0] for r in csv.reader(handle) if r]
    seen, good, bad = set(), [], []
    for raw in rows:
        value = str(raw).strip()
        if not value or (not good and not bad and "@" not in value):
            continue  # blank line, or a header such as "email"
        if not EMAIL.match(value):
            bad.append(value)
        elif value.lower() not in seen:
            seen.add(value.lower())
            good.append(value)
    return good, bad


def read_key(path):
    key = os.environ.get("POSTAFLY_API_KEY", "").strip()
    if not key and os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            key = handle.read().strip()
    return key


def already_logged():
    done = {}
    if os.path.exists(LOG_PATH):
        with open(LOG_PATH, newline="", encoding="utf-8") as handle:
            for row in csv.DictReader(handle):
                if row.get("http", "").startswith("2"):
                    done[row["address"].lower()] = row
    return done


def log(row):
    fresh = not os.path.exists(LOG_PATH)
    with open(LOG_PATH, "a", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=LOG_FIELDS)
        if fresh:
            writer.writeheader()
        writer.writerow({field: row.get(field, "") for field in LOG_FIELDS})


def call(base, key, method, path, body=None, idempotency=None):
    headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json", "User-Agent": "postafly-paced-send/1.0"}
    if idempotency:
        headers["Idempotency-Key"] = idempotency
    data = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request(base + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.status, json.loads(response.read() or b"{}"), response.headers
    except urllib.error.HTTPError as error:
        raw = error.read() or b""
        try:
            payload = json.loads(raw)
        except ValueError:
            payload = {"message": raw.decode("utf-8", "replace")[:200]}
        return error.code, payload, error.headers


def plan_send_times(count, start_in, interval):
    first = dt.datetime.now(dt.timezone.utc).replace(microsecond=0) + dt.timedelta(minutes=start_in)
    return [first + dt.timedelta(minutes=interval * i) for i in range(count)]


def cancel(base, key):
    batches = []
    if os.path.exists(LOG_PATH):
        with open(LOG_PATH, newline="", encoding="utf-8") as handle:
            batches = [r for r in csv.DictReader(handle) if r.get("batch_id") and r.get("http", "").startswith("2")]
    if not batches:
        print("Nothing in the log to cancel.")
        return 0
    canceled = 0
    for row in batches:
        status, payload, _ = call(base, key, "POST", f"/api/v1/mail/batches/{row['batch_id']}/cancel")
        if status // 100 == 2:
            canceled += 1
        else:
            print(f"  {row['address']}: {status} {payload.get('message', '')}")
    print(f"Cancel requested for {len(batches)} batches ({canceled} accepted; messages already sent cannot be canceled).")
    return 0


def main():
    global LOG_PATH
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--log", default=LOG_PATH, help="where to note what was scheduled (use another file for a one-off test to the same address)")
    parser.add_argument("sheet", nargs="?", help="spreadsheet (.xlsx) or .csv/.txt with one address per line in the first column")
    parser.add_argument("--from", dest="sender", help="verified sender address, e.g. john@zmdservice.com")
    parser.add_argument("--base-url", default="https://postafly.com.pk")
    parser.add_argument("--link", default="https://zmdservice.com", help="the address the link in each mail points to")
    parser.add_argument("--interval", type=float, default=7.0, help="minutes between two mails (default 7, inside the new-account limit of 10 an hour)")
    parser.add_argument("--hourly-limit", type=int, default=10, help="your account's marketing mails per hour (10 while new; raise it here only after it was raised in Admin)")
    parser.add_argument("--start-in", type=float, default=3.0, help="minutes from now until the first mail (default 3)")
    parser.add_argument("--limit", type=int, default=0, help="only the first N addresses")
    parser.add_argument("--key-file", default=os.path.join(HERE, ".api-key"))
    parser.add_argument("--tag", default="first-mails", help="label added to every mail as a category")
    parser.add_argument("--round", default="", help="add to the retry key when the same addresses are re-scheduled with new times after a cancel (e.g. r2)")
    parser.add_argument("--send", action="store_true", help="really schedule the mails (without it only the plan is shown)")
    parser.add_argument("--cancel", action="store_true", help="cancel every still-scheduled mail in the log")
    args = parser.parse_args()
    LOG_PATH = os.path.abspath(args.log)
    base = args.base_url.rstrip("/")

    if args.cancel:
        key = read_key(args.key_file)
        if not key:
            sys.exit("No API key found.")
        return cancel(base, key)

    if not args.sheet or not args.sender:
        parser.error("give the sheet and --from")
    addresses, bad = read_addresses(args.sheet)
    if bad:
        print(f"Skipping {len(bad)} line(s) that are not email addresses: {', '.join(bad[:5])}")
    if args.limit:
        addresses = addresses[: args.limit]
    done = already_logged()
    todo = [a for a in addresses if a.lower() not in done]
    print(f"{len(addresses)} addresses in the sheet, {len(addresses) - len(todo)} already scheduled earlier, {len(todo)} to do.")
    if not todo:
        return 0
    per_hour = min(len(todo), int(60 / args.interval) + 1)   # the most mails that can fall inside any one hour
    if per_hour > args.hourly_limit:
        sys.exit(
            f"One mail every {args.interval:g} minutes puts up to {per_hour} mails inside an hour, but your hourly marketing limit is {args.hourly_limit}. "
            "The server would hold the extra mails back until room frees up. Use a longer --interval, or raise the hourly limit in Admin first "
            "and pass --hourly-limit with the new number."
        )
    for domain in ("outlook.com", "hotmail.com", "live.com", "gmail.com", "googlemail.com", "yahoo.com"):
        count = sum(1 for a in todo if a.lower().endswith("@" + domain))
        if count > 50:
            print(f"Note: {count} of these go to {domain}; new accounts may send only 50 a day to each big provider, so the rest would wait for the next day.")

    times = plan_send_times(len(todo), args.start_in, args.interval)
    if times[-1] - dt.datetime.now(dt.timezone.utc) > dt.timedelta(hours=70):
        sys.exit("That run would reach more than 70 hours ahead; the API only schedules up to 72. Use --limit and do the rest later.")
    print(f"First mail {times[0]:%Y-%m-%d %H:%M} UTC, last {times[-1]:%Y-%m-%d %H:%M} UTC, one every {args.interval:g} minutes.\n")
    for i, (address, when) in enumerate(zip(todo, times)):
        template = TEMPLATES[(len(done) + i) % len(TEMPLATES)]
        print(f"  {when:%H:%M}  {template['key']:<15} {address}")

    if not args.send:
        print("\nThis was only the plan. Add --send to schedule it.")
        return 0

    key = read_key(args.key_file)
    if not key.startswith("SGR."):
        sys.exit(f"No usable API key. Save it (the whole text, starting SGR.) in {args.key_file}")
    print()
    accepted = 0
    for i, (address, when) in enumerate(zip(todo, times)):
        template = TEMPLATES[(len(done) + i) % len(TEMPLATES)]
        html, text = render(template, args.link)
        body = {
            "fromEmail": args.sender,
            "toEmail": address,
            "subject": template["subject"],
            "htmlContent": html,
            "textContent": text,
            "stream": "MARKETING",
            "categories": [args.tag, template["key"]],
            "sendAt": when.strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
        idem = f"{args.tag}{'-' + args.round if args.round else ''}-{hashlib.sha1(address.lower().encode()).hexdigest()[:16]}"
        for attempt in range(4):
            try:
                status, payload, headers = call(base, key, "POST", "/api/v1/mail/send", body, idem)
            except (urllib.error.URLError, OSError) as error:
                status, payload, headers = 0, {"message": f"network problem: {error}"}, {}
            if status == 429 and attempt < 3:
                time.sleep(min(60, int(headers.get("Retry-After", "5") or 5)))
                continue
            if status == 0 and attempt < 3:
                time.sleep(5 * (attempt + 1))
                continue
            break
        ok = status // 100 == 2
        row = {"address": address, "template": template["key"], "send_at": body["sendAt"], "http": status}
        if ok:
            row.update(status=payload.get("status", ""), message_id=payload.get("messageId", ""), batch_id=payload.get("batchId", ""))
            accepted += 1
            print(f"  ok    {address}  ({payload.get('status', '')})")
        else:
            row.update(note=str(payload.get("message", payload))[:300])
            print(f"  FAIL  {address}  {status}  {row['note']}")
        log(row)
        if status in (401, 403):
            sys.exit("\nThe API key was not accepted (or lacks the 'Send email' permission). Stopping.")
        if status == 422:
            sys.exit("\nThe server refused this mail (sender not verified, a limit, or compliance details missing). Stopping so nothing else is wasted.")
        time.sleep(0.3 + random.random() * 0.2)
    print(f"\n{accepted} of {len(todo)} scheduled. Log: {LOG_PATH}")
    return 0 if accepted == len(todo) else 1


if __name__ == "__main__":
    sys.exit(main())
