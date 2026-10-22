#!/usr/bin/env python3
"""Postafly delivery log shipper.

Runs on each mail server. It follows Postfix's mail log and reports every delivery attempt (delivered,
deferred, bounced, expired) to the backend, which turns them into message events.

How a log line finds its message: for customer mail the envelope sender is bounce+<message id>@bounces.<domain>,
and Postfix logs it once per message (qmgr "from=<...>"). Every later delivery line for that queue id (possibly
days later, after retries) is matched through it. The sender of still-queued messages is kept in the state file,
so a restart does not lose track of them; if one is ever unknown, `postqueue -j` is asked as a last resort.

Safety properties:
  * Nothing is lost on a restart: the read position is saved only after the backend acknowledged what came before it.
  * Re-sending is harmless: the backend ignores a report it has already seen.
  * A report the backend says "retry" for (the app has not recorded the hand-over yet) is held back and re-sent,
    and after RETRY_FORCE_AFTER seconds it is sent with force=true so it can never be stuck forever.
  * The backend being down only delays reports; they are re-sent with growing pauses.
Standard library only.
"""
import argparse
import json
import logging
import os
import re
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from collections import OrderedDict
from datetime import datetime, timezone

log = logging.getLogger("postafly-logship")

# 2026-10-22T01:32:56.123456+00:00 smtp-mail-1 postfix/smtp[2578392]: 55F025C0041: to=<...>, ...
# Oct 22 01:32:56 smtp-mail-1 postfix/smtp[2578392]: 55F025C0041: to=<...>, ...   (traditional syslog)
LINE = re.compile(
    r"^(?P<ts>\d{4}-\d\d-\d\dT\S+|[A-Z][a-z]{2}\s+\d+\s+\d\d:\d\d:\d\d)\s+(?P<host>\S+)\s+"
    r"postfix(?:-[\w.]+)?/(?P<prog>[\w/-]+)\[(?P<pid>\d+)\]:\s+(?P<rest>.*)$"
)
QID = re.compile(r"^(?P<qid>[0-9A-Za-z]{9,20}):\s+(?P<msg>.*)$")
FROM = re.compile(r"\bfrom=<(?P<from>[^>]*)>")
EXPIRED = re.compile(r"\bstatus=expired\b")
DELIVERY = re.compile(
    r"\bto=<(?P<to>[^>]*)>,\s+(?:orig_to=<[^>]*>,\s+)?relay=(?P<relay>[^,]*),\s+(?:conn_use=(?P<conn>\d+),\s+)?"
    r"delay=(?P<delay>[\d.]+),\s+delays=(?P<delays>[\d./]+),\s+dsn=(?P<dsn>\d\.\d+\.\d+),\s+"
    r"status=(?P<status>\w+)\s+\((?P<resp>.*)\)\s*$"
)
TLS = re.compile(
    r"^(?P<trust>Trusted|Untrusted|Verified|Anonymous) TLS connection established to (?P<relay>\S+): (?P<proto>\S+) with cipher"
)
BOUNCE_FROM = re.compile(r"^bounce\+[0-9a-fA-F-]{36}@", re.IGNORECASE)

MAX_REMEMBERED = 50000          # queue ids whose sender we remember
RETRY_FORCE_AFTER = 600         # seconds a "retry" report is held back before it is sent with force=true
BATCH_SIZE = 50
FLUSH_EVERY = 2.0
HEARTBEAT_EVERY = 60.0


def parse_ts(raw, now=None):
    """Postfix log timestamp to an ISO-8601 string with offset, or None."""
    try:
        if raw[:4].isdigit():
            return datetime.fromisoformat(raw.replace("Z", "+00:00")).astimezone(timezone.utc).isoformat()
        now = now or datetime.now().astimezone()
        parsed = datetime.strptime("%d %s" % (now.year, raw), "%Y %b %d %H:%M:%S").replace(tzinfo=now.tzinfo)
        if parsed > now:  # a December line read in January
            parsed = parsed.replace(year=now.year - 1)
        return parsed.astimezone(timezone.utc).isoformat()
    except (ValueError, TypeError):
        return None


class Tracker:
    """Turns log lines into delivery reports. Pure logic, no I/O except the optional postqueue fallback."""

    def __init__(self, sender_lookup=None):
        self.senders = OrderedDict()   # queue id -> envelope sender, for messages still in the queue
        self.tls = {}                  # relay string -> [protocol, fresh]
        self.sender_lookup = sender_lookup

    def remember(self, qid, sender):
        self.senders[qid] = sender
        self.senders.move_to_end(qid)
        while len(self.senders) > MAX_REMEMBERED:
            self.senders.popitem(last=False)

    def feed(self, line):
        """Returns a report dict for a delivery attempt, else None."""
        m = LINE.match(line.rstrip("\n"))
        if not m:
            return None
        prog, rest = m.group("prog"), m.group("rest")

        if prog == "smtp":
            t = TLS.match(rest)
            if t:
                self.tls[t.group("relay")] = [t.group("proto"), True]
                return None

        q = QID.match(rest)
        if not q:
            return None
        qid, msg = q.group("qid"), q.group("msg")

        if prog == "qmgr":
            if msg.startswith("removed"):
                self.senders.pop(qid, None)
                return None
            f = FROM.search(msg)
            if f:
                self.remember(qid, f.group("from"))
                if EXPIRED.search(msg):
                    sender = f.group("from")
                    if BOUNCE_FROM.match(sender):
                        self.senders.pop(qid, None)
                        return self._report(m, qid, sender, "", "none", None, None, "expired", "delivery time expired", None)
            return None

        if prog == "smtp":
            d = DELIVERY.search(msg)
            if not d:
                return None
            sender = self.senders.get(qid)
            if sender is None and self.sender_lookup:
                sender = self.sender_lookup(qid)
                if sender is not None:
                    self.remember(qid, sender)
            tls = None
            relay = d.group("relay")
            state = self.tls.get(relay)
            conn = d.group("conn")
            if state is not None and (state[1] or (conn is not None and int(conn) > 1)):
                tls = state[0]
            if state is not None:
                state[1] = False       # the next new connection must announce its own TLS line
            return self._report(m, qid, sender, d.group("to"), relay, float(d.group("delay")), d.group("dsn"),
                                d.group("status"), d.group("resp"), tls)
        return None

    @staticmethod
    def _report(m, qid, sender, to, relay, delay, dsn, status, resp, tls):
        return {
            "queueId": qid,
            "at": parse_ts(m.group("ts")),
            "from": sender,
            "recipient": to,
            "relay": relay,
            "delay": delay,
            "dsn": dsn,
            "status": status,
            "response": resp,
            "tls": tls,
            "force": False,
        }


def postqueue_sender(qid, _cache={"at": 0.0, "map": {}}):
    """Last resort for a queue id whose sender we never saw: ask Postfix, at most every 30 seconds."""
    now = time.time()
    if now - _cache["at"] > 30:
        _cache["at"] = now
        try:
            out = subprocess.run(["postqueue", "-j"], capture_output=True, text=True, timeout=10).stdout
            mapping = {}
            for row in out.splitlines():
                try:
                    item = json.loads(row)
                    mapping[item["queue_id"]] = item.get("sender")
                except (ValueError, KeyError):
                    continue
            _cache["map"] = mapping
        except (OSError, subprocess.SubprocessError):
            pass
    return _cache["map"].get(qid)


class State:
    def __init__(self, path):
        self.path = path
        self.inode = None
        self.offset = 0
        self.senders = {}

    def load(self):
        try:
            with open(self.path) as fh:
                data = json.load(fh)
            self.inode = data.get("inode")
            self.offset = int(data.get("offset", 0))
            self.senders = dict(data.get("senders", {}))
            return True
        except (OSError, ValueError):
            return False

    def save(self, inode, offset, senders):
        data = {"inode": inode, "offset": offset, "senders": senders}
        tmp = self.path + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(data, fh)
        os.replace(tmp, self.path)
        self.inode, self.offset = inode, offset


class Shipper:
    def __init__(self, args):
        self.args = args
        with open(args.token_file) as fh:
            self.token = fh.read().strip()
        self.tracker = Tracker(postqueue_sender if args.postqueue_fallback else None)
        self.state = State(args.state)
        self.pending = []      # reports not yet acknowledged: dict(report, start, end, first_retry)
        self.stop = False
        self.backoff = 1.0
        self.last_send = 0.0
        self.last_flush = 0.0
        self.fd = None
        self.inode = None
        self.pos = 0
        self.saved_offset = -1
        self.backfill_cutoff = None

    def close(self):
        if self.fd is not None:
            self.fd.close()
            self.fd = None

    # ── file following ────────────────────────────────────────────────────────────────────────────
    def open_log(self):
        self.fd = open(self.args.log, "rb")
        self.inode = os.fstat(self.fd.fileno()).st_ino

    def start(self):
        have_state = self.state.load()
        self.open_log()
        if have_state and self.state.inode == self.inode and self.state.offset <= os.fstat(self.fd.fileno()).st_size:
            self.fd.seek(self.state.offset)
            self.pos = self.state.offset
            for qid, sender in self.state.senders.items():
                self.tracker.remember(qid, sender)
            log.info("resuming at offset %d", self.pos)
        elif self.args.from_end and not have_state:
            self.fd.seek(0, os.SEEK_END)
            self.pos = self.fd.tell()
            log.info("first run, starting at the end of the log")
        else:
            self.pos = 0
            if not have_state and self.args.backfill_hours > 0:
                self.backfill_cutoff = datetime.now(timezone.utc).timestamp() - self.args.backfill_hours * 3600
            for qid, sender in self.state.senders.items():
                self.tracker.remember(qid, sender)
            log.info("reading the log from the start (backfill window %sh)", self.args.backfill_hours)

    def read_new_lines(self):
        """Reads whatever complete lines are available; handles rotation and truncation."""
        lines = []
        while True:
            start = self.fd.tell()
            raw = self.fd.readline()
            if not raw:
                break
            if not raw.endswith(b"\n"):
                self.fd.seek(start)        # half-written line: wait for the rest
                break
            lines.append((raw.decode("utf-8", "replace"), start, self.fd.tell()))
            if len(lines) >= 2000:
                break
        if lines:
            self.pos = lines[-1][2]
            return lines
        try:
            st = os.stat(self.args.log)
        except OSError:
            return lines
        if st.st_ino != self.inode:        # rotated: the old file is fully read, move to the new one
            log.info("log rotated, reopening")
            self.fd.close()
            self.open_log()
            self.pos = 0
        elif st.st_size < self.pos:        # truncated in place
            log.info("log truncated, starting over")
            self.fd.seek(0)
            self.pos = 0
        return lines

    def collect(self, lines):
        for text, start, end in lines:
            report = self.tracker.feed(text)
            if report is None:
                continue
            if self.backfill_cutoff is not None and report["at"]:
                if datetime.fromisoformat(report["at"]).timestamp() < self.backfill_cutoff:
                    continue
            self.pending.append({"report": report, "start": start, "end": end, "first_retry": None})

    # ── talking to the backend ────────────────────────────────────────────────────────────────────
    def post(self, reports):
        body = json.dumps({"host": self.args.host, "events": reports}).encode()
        req = urllib.request.Request(self.args.url, data=body, method="POST", headers={
            "Content-Type": "application/json",
            "X-Postafly-Relay-Token": self.token,
        })
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.load(resp)["results"]

    def flush(self, force_heartbeat=False):
        now = time.time()
        due = [p for p in self.pending if p.get("next", 0) <= now]
        if not due and not (force_heartbeat or now - self.last_send >= HEARTBEAT_EVERY):
            return
        batch = due[:BATCH_SIZE]
        reports = []
        for item in batch:
            report = dict(item["report"])
            if item["first_retry"] is not None and now - item["first_retry"] > RETRY_FORCE_AFTER:
                report["force"] = True
            reports.append(report)
        try:
            results = self.post(reports)
        except (urllib.error.URLError, OSError, ValueError, KeyError) as exc:
            log.warning("backend not reachable (%s); will retry in %.0fs", exc, self.backoff)
            self.backoff = min(self.backoff * 2, 60.0)
            for item in batch:
                item["next"] = now + self.backoff
            return
        self.backoff = 1.0
        self.last_send = now
        self.last_flush = now
        for item, result in zip(batch, results):
            if result == "retry":
                if item["first_retry"] is None:
                    item["first_retry"] = now
                item["next"] = now + 10
            else:
                self.pending.remove(item)
        counts = {}
        for result in results:
            counts[result] = counts.get(result, 0) + 1
        if batch:
            log.info("sent %d report(s): %s", len(batch), counts)

    def checkpoint(self, final=False):
        offset = min([p["start"] for p in self.pending], default=self.pos)
        if offset != self.saved_offset or final:
            try:
                self.state.save(self.inode, offset, dict(self.tracker.senders))
                self.saved_offset = offset
            except OSError as exc:
                log.warning("could not save state: %s", exc)

    def run(self):
        self.start()
        signal.signal(signal.SIGTERM, lambda *_: setattr(self, "stop", True))
        signal.signal(signal.SIGINT, lambda *_: setattr(self, "stop", True))
        while not self.stop:
            lines = self.read_new_lines()
            self.collect(lines)
            ready = len([p for p in self.pending if p.get("next", 0) <= time.time()])
            if ready >= BATCH_SIZE or (ready and time.time() - self.last_flush >= FLUSH_EVERY) or not lines:
                self.flush()
            self.checkpoint()
            if not lines:
                time.sleep(0.5)
        self.flush(force_heartbeat=False)
        self.checkpoint(final=True)
        self.close()
        log.info("stopped")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--log", default="/var/log/mail.log")
    ap.add_argument("--url", required=True, help="e.g. http://10.10.1.4:8080/api/v1/internal/delivery-events")
    ap.add_argument("--token-file", required=True)
    ap.add_argument("--state", default="/var/lib/postafly-logship/state.json")
    ap.add_argument("--host", default=socket.gethostname())
    ap.add_argument("--backfill-hours", type=float, default=72, help="on the very first run, ignore reports older than this")
    ap.add_argument("--from-end", action="store_true", help="on the very first run, start at the end of the log")
    ap.add_argument("--no-postqueue-fallback", dest="postqueue_fallback", action="store_false")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, stream=sys.stderr, format="%(levelname)s %(message)s")
    Shipper(args).run()


if __name__ == "__main__":
    main()
