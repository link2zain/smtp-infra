"""Tests for the log shipper's parsing and file handling. Run: python -m unittest -v test_logship"""
import importlib.util
import json
import os
import shutil
import tempfile
import unittest
from collections import namedtuple

spec = importlib.util.spec_from_file_location("logship", os.path.join(os.path.dirname(__file__), "postafly-logship.py"))
logship = importlib.util.module_from_spec(spec)
spec.loader.exec_module(logship)

UUID = "99999999-0000-4000-8000-00000000c0c0"
BOUNCE = "bounce+" + UUID + "@bounces.postafly.com.pk"

# Lines copied from a real mail server (queue DFADA5C0041), then variations Postfix produces for other outcomes.
REAL_SENT = [
    "2026-10-22T01:33:01.100000+00:00 smtp-mail-1 postfix/smtpd[2578388]: DFADA5C0041: client=unknown[10.10.1.4]",
    "2026-10-22T01:33:01.110000+00:00 smtp-mail-1 postfix/cleanup[2578391]: DFADA5C0041: message-id=<rp-test-" + UUID + "@postafly.com.pk>",
    "2026-10-22T01:33:01.130000+00:00 smtp-mail-1 postfix/qmgr[2574001]: DFADA5C0041: from=<" + BOUNCE + ">, size=521, nrcpt=1 (queue active)",
    "2026-10-22T01:33:03.300000+00:00 smtp-mail-1 postfix/smtp[2578392]: DFADA5C0041: to=<sheharyar@yasaardata.com>, relay=mail.yasaardata.com[104.247.79.239]:25, delay=2.2, delays=0/0/1.5/0.68, dsn=2.0.0, status=sent (250 OK id=1xJeJD-00000007gW8-2Kep)",
    "2026-10-22T01:33:03.310000+00:00 smtp-mail-1 postfix/qmgr[2574001]: DFADA5C0041: removed",
]


def run(lines, tracker=None):
    tracker = tracker or logship.Tracker()
    return [r for r in (tracker.feed(l) for l in lines) if r], tracker


class ParsingTests(unittest.TestCase):
    def test_a_real_delivery_is_reported_with_everything_the_backend_needs(self):
        reports, _ = run(REAL_SENT)

        self.assertEqual(len(reports), 1)
        r = reports[0]
        self.assertEqual(r["queueId"], "DFADA5C0041")
        self.assertEqual(r["from"], BOUNCE)
        self.assertEqual(r["recipient"], "sheharyar@yasaardata.com")
        self.assertEqual(r["relay"], "mail.yasaardata.com[104.247.79.239]:25")
        self.assertEqual(r["status"], "sent")
        self.assertEqual(r["dsn"], "2.0.0")
        self.assertEqual(r["delay"], 2.2)
        self.assertEqual(r["response"], "250 OK id=1xJeJD-00000007gW8-2Kep")
        self.assertEqual(r["at"], "2026-10-22T01:33:03.300000+00:00")
        self.assertFalse(r["force"])

    def test_a_bounce_keeps_the_servers_whole_explanation(self):
        lines = REAL_SENT[:3] + [
            "2026-10-22T01:33:03.300000+00:00 smtp-mail-1 postfix/smtp[2578392]: DFADA5C0041: to=<nobody@zmdservice.com>, relay=mail.zmdservice.com[38.99.2.38]:25, delay=1.4, delays=0/0/0.9/0.5, dsn=5.1.1, status=bounced (host mail.zmdservice.com[38.99.2.38] said: 550 5.1.1 <nobody@zmdservice.com>: Recipient address rejected: User unknown in virtual mailbox table (in reply to RCPT TO command))",
        ]
        reports, _ = run(lines)

        self.assertEqual(reports[0]["status"], "bounced")
        self.assertEqual(reports[0]["dsn"], "5.1.1")
        self.assertTrue(reports[0]["response"].startswith("host mail.zmdservice.com[38.99.2.38] said: 550 5.1.1"))
        self.assertTrue(reports[0]["response"].endswith("(in reply to RCPT TO command)"))

    def test_a_deferral_with_no_connection_still_parses(self):
        lines = REAL_SENT[:3] + [
            "2026-10-22T01:34:03.300000+00:00 smtp-mail-1 postfix/smtp[2578392]: DFADA5C0041: to=<x@slow.example>, relay=none, delay=30, delays=0.1/0/30/0, dsn=4.4.1, status=deferred (connect to slow.example[1.2.3.4]:25: Connection timed out)",
        ]
        reports, _ = run(lines)

        self.assertEqual(reports[0]["status"], "deferred")
        self.assertEqual(reports[0]["relay"], "none")
        self.assertEqual(reports[0]["response"], "connect to slow.example[1.2.3.4]:25: Connection timed out")

    def test_a_retry_days_later_is_matched_to_its_message_without_a_second_from_line(self):
        tracker = logship.Tracker()
        run(REAL_SENT[:3], tracker)   # message enters the queue; no delivery yet
        later = "2026-10-24T09:00:00.000000+00:00 smtp-mail-1 postfix/smtp[2600001]: DFADA5C0041: to=<x@y.example>, relay=mx.y.example[1.2.3.4]:25, delay=170000, delays=0/0.01/0.5/1.2, dsn=2.0.0, status=sent (250 2.0.0 OK)"
        reports, _ = run([later], tracker)

        self.assertEqual(reports[0]["from"], BOUNCE)

    def test_the_bounce_notice_postfix_files_locally_is_not_reported_as_a_delivery(self):
        lines = [
            "2026-10-22T01:33:05.000000+00:00 smtp-mail-1 postfix/qmgr[2574001]: AAAA5C0041: from=<>, size=2300, nrcpt=1 (queue active)",
            "2026-10-22T01:33:05.100000+00:00 smtp-mail-1 postfix/virtual[2578400]: AAAA5C0041: to=<" + BOUNCE + ">, relay=virtual, delay=0.02, delays=0.01/0.01/0/0, dsn=2.0.0, status=sent (delivered to maildir)",
        ]
        reports, _ = run(lines)

        self.assertEqual(reports, [])   # program is "virtual", not "smtp"

    def test_expiry_of_customer_mail_is_reported_but_system_mail_is_not(self):
        customer = "2026-10-27T01:33:05.000000+00:00 smtp-mail-1 postfix/qmgr[2574001]: BBBB5C0041: from=<" + BOUNCE + ">, status=expired, returned to sender"
        system = "2026-10-27T01:33:06.000000+00:00 smtp-mail-1 postfix/qmgr[2574001]: CCCC5C0041: from=<noreply@postafly.com.pk>, status=expired, returned to sender"
        reports, _ = run([customer, system])

        self.assertEqual(len(reports), 1)
        self.assertEqual(reports[0]["status"], "expired")
        self.assertEqual(reports[0]["queueId"], "BBBB5C0041")

    def test_tls_is_attached_to_the_delivery_that_used_it(self):
        relay = "mail.yasaardata.com[104.247.79.239]:25"
        lines = [
            REAL_SENT[2],
            "2026-10-22T01:33:02.900000+00:00 smtp-mail-1 postfix/smtp[2578392]: Untrusted TLS connection established to " + relay + ": TLSv1.3 with cipher TLS_AES_256_GCM_SHA384 (256/256 bits) key-exchange X25519 server-signature RSA-PSS (2048 bits) server-digest SHA256",
            REAL_SENT[3],
        ]
        reports, _ = run(lines)

        self.assertEqual(reports[0]["tls"], "TLSv1.3")

    def test_a_new_plain_connection_does_not_inherit_the_previous_connections_tls(self):
        relay = "mx.example.net[1.2.3.4]:25"
        tracker = logship.Tracker()
        tls_line = "2026-10-22T01:33:02.900000+00:00 smtp-mail-1 postfix/smtp[1]: Untrusted TLS connection established to " + relay + ": TLSv1.2 with cipher X"
        first = "2026-10-22T01:33:03.000000+00:00 smtp-mail-1 postfix/smtp[1]: QQQQ5C0041: to=<a@b.example>, relay=" + relay + ", delay=1, delays=0/0/0.5/0.5, dsn=2.0.0, status=sent (250 OK)"
        second_new_connection = "2026-10-22T02:00:00.000000+00:00 smtp-mail-1 postfix/smtp[1]: RRRR5C0041: to=<c@d.example>, relay=" + relay + ", delay=1, delays=0/0/0.5/0.5, dsn=2.0.0, status=sent (250 OK)"
        for qid, bounce in (("QQQQ5C0041", BOUNCE), ("RRRR5C0041", BOUNCE)):
            tracker.remember(qid, bounce)
        reports, _ = run([tls_line, first, second_new_connection], tracker)

        self.assertEqual(reports[0]["tls"], "TLSv1.2")
        self.assertIsNone(reports[1]["tls"])

    def test_a_reused_connection_keeps_its_tls(self):
        relay = "mx.example.net[1.2.3.4]:25"
        tracker = logship.Tracker()
        tracker.remember("QQQQ5C0041", BOUNCE)
        tracker.remember("RRRR5C0041", BOUNCE)
        lines = [
            "2026-10-22T01:33:02.900000+00:00 smtp-mail-1 postfix/smtp[1]: Untrusted TLS connection established to " + relay + ": TLSv1.3 with cipher X",
            "2026-10-22T01:33:03.000000+00:00 smtp-mail-1 postfix/smtp[1]: QQQQ5C0041: to=<a@b.example>, relay=" + relay + ", delay=1, delays=0/0/0.5/0.5, dsn=2.0.0, status=sent (250 OK)",
            "2026-10-22T01:33:04.000000+00:00 smtp-mail-1 postfix/smtp[1]: RRRR5C0041: to=<c@d.example>, relay=" + relay + ", conn_use=2, delay=1, delays=0/0/0.5/0.5, dsn=2.0.0, status=sent (250 OK)",
        ]
        reports, _ = run(lines, tracker)

        self.assertEqual([r["tls"] for r in reports], ["TLSv1.3", "TLSv1.3"])

    def test_unrelated_lines_are_ignored(self):
        junk = [
            "",
            "garbage that is not a log line",
            "2026-10-22T01:33:00+00:00 smtp-mail-1 postfix/anvil[1]: statistics: max connection rate 1/60s for (smtp:1.2.3.4) at Oct 22 01:30:00",
            "2026-10-22T01:33:00+00:00 smtp-mail-1 postfix/smtpd[1]: connect from unknown[1.2.3.4]",
            "2026-10-22T01:33:00+00:00 smtp-mail-1 postfix/smtpd[1]: NOQUEUE: reject: RCPT from unknown[1.2.3.4]: 554 5.7.1 <x@gmail.com>: Relay access denied",
        ]
        reports, _ = run(junk)

        self.assertEqual(reports, [])

    def test_traditional_syslog_timestamps_are_understood(self):
        iso = logship.parse_ts("Oct 22 01:33:03")

        self.assertTrue(iso.startswith(str(__import__("datetime").datetime.now().year)) or iso.startswith(str(__import__("datetime").datetime.now().year - 1)))
        self.assertIsNone(logship.parse_ts("not a time"))

    def test_an_unknown_sender_is_looked_up_once_as_a_last_resort(self):
        asked = []
        tracker = logship.Tracker(lambda qid: asked.append(qid) or BOUNCE)
        line = "2026-10-22T01:33:03.300000+00:00 smtp-mail-1 postfix/smtp[1]: ZZZZ5C0041: to=<a@b.example>, relay=mx.example.net[1.2.3.4]:25, delay=1, delays=0/0/0.5/0.5, dsn=2.0.0, status=sent (250 OK)"
        reports, _ = run([line, line], tracker)

        self.assertEqual(reports[0]["from"], BOUNCE)
        self.assertEqual(asked, ["ZZZZ5C0041"])   # remembered after the first lookup


class FileFollowingTests(unittest.TestCase):
    """The shipper against a real file: ordering, partial lines, acknowledgements and resuming."""

    Args = namedtuple("Args", "log url token_file state host backfill_hours from_end postqueue_fallback")

    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.shippers = []

    def tearDown(self):
        for shipper in self.shippers:
            shipper.close()
        shutil.rmtree(self.d, ignore_errors=True)

    def make(self, log_lines=None):
        log_path = os.path.join(self.d, "mail.log")
        token = os.path.join(self.d, "token")
        with open(token, "w") as fh:
            fh.write("secret-token\n")
        if log_lines is not None:
            with open(log_path, "w") as fh:
                fh.write("\n".join(log_lines) + "\n")
        args = self.Args(log_path, "http://backend.invalid/ingest", token, os.path.join(self.d, "state.json"), "smtp-mail-1", 0, False, False)
        shipper = logship.Shipper(args)
        self.shippers.append(shipper)
        return shipper, log_path

    def state(self):
        with open(os.path.join(self.d, "state.json")) as fh:
            return json.load(fh)

    def test_reports_are_sent_in_order_and_the_position_is_saved_after_acknowledgement(self):
        shipper, path = self.make(REAL_SENT)
        sent = []
        shipper.post = lambda reports: sent.extend(reports) or ["applied"] * len(reports)
        shipper.start()
        shipper.collect(shipper.read_new_lines())
        shipper.flush(force_heartbeat=True)
        shipper.checkpoint()

        self.assertEqual([r["queueId"] for r in sent], ["DFADA5C0041"])
        self.assertEqual(self.state()["offset"], os.path.getsize(path))

    def test_a_retry_answer_holds_the_report_and_blocks_the_saved_position(self):
        shipper, path = self.make(REAL_SENT)
        shipper.post = lambda reports: ["retry"] * len(reports)
        shipper.start()
        shipper.collect(shipper.read_new_lines())
        shipper.flush(force_heartbeat=True)
        shipper.checkpoint()

        self.assertEqual(len(shipper.pending), 1)
        self.assertLess(self.state()["offset"], os.path.getsize(path))   # will be re-read after a restart

    def test_a_report_held_back_for_too_long_is_sent_with_force(self):
        shipper, _ = self.make(REAL_SENT)
        seen = []
        shipper.post = lambda reports: seen.append([dict(r) for r in reports]) or ["retry"] * len(reports)
        shipper.start()
        shipper.collect(shipper.read_new_lines())
        shipper.flush(force_heartbeat=True)
        shipper.pending[0]["first_retry"] -= logship.RETRY_FORCE_AFTER + 5
        shipper.pending[0]["next"] = 0
        shipper.flush(force_heartbeat=True)

        self.assertFalse(seen[0][0]["force"])
        self.assertTrue(seen[1][0]["force"])

    def test_a_backend_outage_keeps_everything_and_slows_down(self):
        import urllib.error
        shipper, _ = self.make(REAL_SENT)

        def down(_):
            raise urllib.error.URLError("backend down")
        shipper.post = down
        shipper.start()
        shipper.collect(shipper.read_new_lines())
        shipper.flush(force_heartbeat=True)

        self.assertEqual(len(shipper.pending), 1)
        self.assertGreater(shipper.backoff, 1.0)

    def test_a_half_written_line_waits_for_its_end(self):
        shipper, path = self.make([])
        open(path, "w").close()
        shipper.start()
        with open(path, "a") as fh:
            fh.write(REAL_SENT[2] + "\n")
            fh.write(REAL_SENT[3][:60])         # cut in the middle of the delivery line
        shipper.collect(shipper.read_new_lines())
        self.assertEqual(len(shipper.pending), 0)
        with open(path, "a") as fh:
            fh.write(REAL_SENT[3][60:] + "\n")
        shipper.collect(shipper.read_new_lines())

        self.assertEqual(len(shipper.pending), 1)

    def test_it_resumes_where_it_left_off_and_remembers_queued_senders(self):
        shipper, path = self.make(REAL_SENT[:3])      # message queued, not yet delivered
        shipper.start()
        shipper.collect(shipper.read_new_lines())
        shipper.checkpoint(final=True)
        shipper.close()

        with open(path, "a") as fh:
            fh.write(REAL_SENT[3] + "\n")
        again, _ = self.make()
        sent = []
        again.post = lambda reports: sent.extend(reports) or ["applied"] * len(reports)
        again.start()
        again.collect(again.read_new_lines())
        again.flush(force_heartbeat=True)

        self.assertEqual(len(sent), 1)
        self.assertEqual(sent[0]["from"], BOUNCE)         # known only because the state file kept it

    @unittest.skipIf(os.name == "nt", "Windows cannot rename a file that is open; verified on the Linux mail servers instead")
    def test_a_rotated_log_is_followed_to_the_new_file(self):
        shipper, path = self.make(REAL_SENT[:3])
        shipper.start()
        shipper.collect(shipper.read_new_lines())
        os.rename(path, path + ".1")
        with open(path, "w") as fh:
            fh.write(REAL_SENT[3] + "\n")
        shipper.collect(shipper.read_new_lines())       # reaches the end of the old file, then switches
        shipper.collect(shipper.read_new_lines())

        self.assertEqual(len(shipper.pending), 1)

    def test_old_reports_are_skipped_on_the_first_run_when_backfill_is_limited(self):
        shipper, _ = self.make(REAL_SENT)
        shipper.args = shipper.args._replace(backfill_hours=1)   # the lines are from 2026-10-22; "now" is later
        shipper.start()
        shipper.collect(shipper.read_new_lines())

        self.assertEqual(shipper.pending, [])


if __name__ == "__main__":
    unittest.main()
