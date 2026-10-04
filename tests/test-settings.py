#!/usr/bin/env python3
"""Unit tests for the proton-sync-settings helper functions.

Runs headless (no window is created); GTK only needs to be importable.
"""

import importlib.machinery
import importlib.util
import json
import os
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Sandbox the XDG dirs BEFORE importing the module (its constants read them).
_SANDBOX = tempfile.mkdtemp(prefix="proton-sync-pytest.")
os.environ["XDG_CONFIG_HOME"] = os.path.join(_SANDBOX, "config")
os.environ["XDG_STATE_HOME"] = os.path.join(_SANDBOX, "state")

loader = importlib.machinery.SourceFileLoader(
    "psset", os.path.join(ROOT, "bin", "proton-sync-settings"))
spec = importlib.util.spec_from_loader("psset", loader)
psset = importlib.util.module_from_spec(spec)
sys.modules["psset"] = psset
loader.exec_module(psset)


class ConfigRoundTrip(unittest.TestCase):
    def test_values_survive_quoting(self):
        cases = {
            "LOCAL_ROOT": "/home/user/My Files/O'Brien's Photos",
            "REMOTE_ROOT": "/my-files/Desk top",
            "POLL_INTERVAL": "300",
            "SYNC_DELETES": "true",
        }
        psset.save_config(cases)
        self.assertEqual(psset.load_config(), cases)

    def test_config_is_valid_shell(self):
        psset.save_config({"LOCAL_ROOT": "/tmp/it's a \"test\""})
        rc = os.system(f"bash -n {psset.CONFIG_FILE!r} && "
                       f"bash -c 'source {psset.CONFIG_FILE!r}'")
        self.assertEqual(rc, 0)

    def test_missing_config_gives_empty_dict(self):
        if os.path.exists(psset.CONFIG_FILE):
            os.remove(psset.CONFIG_FILE)
        self.assertEqual(psset.load_config(), {})


class ExcludesRoundTrip(unittest.TestCase):
    def test_roundtrip_with_spaces(self):
        paths = ["/a/Camera Roll", "/b/x"]
        psset.save_excludes(paths)
        self.assertEqual(psset.load_excludes(), paths)


class HumanBytes(unittest.TestCase):
    def test_formatting(self):
        self.assertEqual(psset.human_bytes(0), "0 B")
        self.assertEqual(psset.human_bytes(512), "512 B")
        self.assertEqual(psset.human_bytes(1024), "1.0 KiB")
        self.assertEqual(psset.human_bytes(1536), "1.5 KiB")
        self.assertEqual(psset.human_bytes(160_000_000), "152.6 MiB")
        self.assertEqual(psset.human_bytes(53 * 1024**3), "53.0 GiB")


class HistoryReading(unittest.TestCase):
    def test_skips_malformed_lines(self):
        os.makedirs(os.path.dirname(psset.HISTORY_FILE), exist_ok=True)
        with open(psset.HISTORY_FILE, "w") as f:
            f.write(json.dumps({"start": 1, "end": 2, "bytes": 10}) + "\n")
            f.write("not json at all\n")
            f.write(json.dumps({"start": 3, "end": 4, "bytes": 20}) + "\n")
        rows = psset.read_history()
        self.assertEqual([r["bytes"] for r in rows], [10, 20])

    def test_missing_file_gives_empty(self):
        if os.path.exists(psset.HISTORY_FILE):
            os.remove(psset.HISTORY_FILE)
        self.assertEqual(psset.read_history(), [])


class LogTail(unittest.TestCase):
    def test_missing_log_is_empty_string(self):
        if os.path.exists(psset.LOG_FILE):
            os.remove(psset.LOG_FILE)
        self.assertEqual(psset.read_log_tail(), "")

    def test_tail_limits_lines(self):
        os.makedirs(os.path.dirname(psset.LOG_FILE), exist_ok=True)
        with open(psset.LOG_FILE, "w") as f:
            for i in range(500):
                f.write(f"line {i}\n")
        tail = psset.read_log_tail(max_lines=100)
        lines = tail.splitlines()
        self.assertEqual(len(lines), 100)
        self.assertEqual(lines[-1], "line 499")


class PollInterval(unittest.TestCase):
    """POLL_INTERVAL stays in seconds on disk; the UI edits whole minutes."""

    def test_seconds_to_minutes(self):
        self.assertEqual(psset.poll_minutes_from_config("3600"), 60)
        self.assertEqual(psset.poll_minutes_from_config("300"), 5)
        self.assertEqual(psset.poll_minutes_from_config("90"), 2)    # half up
        self.assertEqual(psset.poll_minutes_from_config("20"), 1)    # never 0
        self.assertEqual(psset.poll_minutes_from_config(None), 5)    # default
        self.assertEqual(psset.poll_minutes_from_config("junk"), 5)
        self.assertEqual(psset.poll_minutes_from_config("0"), 5)

    def test_minutes_to_seconds(self):
        self.assertEqual(psset.poll_minutes_to_config(60), "3600")
        self.assertEqual(psset.poll_minutes_to_config(1), "60")
        self.assertEqual(psset.poll_minutes_to_config(0), "60")

    def test_roundtrip(self):
        for m in (1, 5, 60, 1440):
            self.assertEqual(
                psset.poll_minutes_from_config(psset.poll_minutes_to_config(m)), m)


class FullCheckInterval(unittest.TestCase):
    def test_hours_conversion(self):
        self.assertEqual(psset.hours_from_config("86400"), 24)
        self.assertEqual(psset.hours_from_config("5400"), 2)      # half up
        self.assertEqual(psset.hours_from_config(None), 24)
        self.assertEqual(psset.hours_from_config("0"), 24)
        self.assertEqual(psset.hours_to_config(24), "86400")
        self.assertEqual(psset.hours_to_config(0), "3600")
        for h in (1, 24, 720):
            self.assertEqual(psset.hours_from_config(psset.hours_to_config(h)), h)

    def test_full_verification_is_plain_syncing_with_a_hint(self):
        self.assertEqual(psset.state_title("syncing", {"mode": "quick"})[1], "Syncing")
        self.assertEqual(psset.state_title("syncing", {"mode": "full"})[1], "Syncing")
        self.assertEqual(psset.state_title("nonsense", None)[1], "No sync activity yet")
        d = psset.SettingsWindow._state_detail(
            "syncing", {"mode": "full", "current": "/h/Desktop/Docs"}, "/h/Desktop")
        self.assertEqual(d, "Checking all files · Uploading Docs")
        d = psset.SettingsWindow._state_detail(
            "syncing", {"mode": "quick", "current": "/h/Desktop/Docs"}, "/h/Desktop")
        self.assertEqual(d, "Uploading Docs")
        self.assertEqual(psset.describe_event("pass-start", "", "full"),
                         ("busy", "Sync started", "checking all files"))
        self.assertEqual(psset.describe_event("pass-start", "", "quick")[2], "")


class RelativeName(unittest.TestCase):
    def test_inside_root(self):
        self.assertEqual(psset.relative_name("/h/Desktop/Fotos/2017", "/h/Desktop"),
                         "Fotos/2017")

    def test_root_with_trailing_slash(self):
        self.assertEqual(psset.relative_name("/h/Desktop/a", "/h/Desktop/"), "a")

    def test_outside_root_stays_absolute(self):
        self.assertEqual(psset.relative_name("/h/Other/a", "/h/Desktop"), "/h/Other/a")
        self.assertEqual(psset.relative_name("/h/Desktop2/a", "/h/Desktop"), "/h/Desktop2/a")

    def test_root_itself_and_no_root(self):
        self.assertEqual(psset.relative_name("/h/Desktop", "/h/Desktop"), "/h/Desktop")
        self.assertEqual(psset.relative_name("/h/Desktop/a", ""), "/h/Desktop/a")
        self.assertEqual(psset.relative_name("/h/Desktop/a", None), "/h/Desktop/a")


class Checks(unittest.TestCase):
    def test_login(self):
        sev, title, advice = psset.login_check_result(None, None, "")
        self.assertEqual(sev, "fail")
        self.assertIn("CLI not found", title)
        self.assertEqual(psset.login_check_result("/x/cli", 0, "")[0], "ok")
        sev, title, advice = psset.login_check_result("/x/cli", 1, "You need to login first")
        self.assertEqual(sev, "fail")
        self.assertIn("Not logged in", title)
        self.assertIn("/x/cli auth login", advice)
        self.assertEqual(psset.login_check_result("/x/cli", 1, "ECONNRESET")[0], "warn")
        self.assertEqual(psset.login_check_result("/x/cli", None, "")[0], "warn")

    def test_service(self):
        self.assertEqual(psset.service_check_result(True, False)[0], "ok")
        self.assertEqual(psset.service_check_result(True, None)[0], "ok")
        sev, _, advice = psset.service_check_result(False, True)
        self.assertEqual(sev, "fail")
        self.assertTrue(advice)                       # explains it comes back
        sev, _, advice = psset.service_check_result(False, None)
        self.assertEqual((sev, advice), ("fail", ""))  # autostart unknown yet
        sev, title, advice = psset.service_check_result(False, False)
        self.assertEqual(sev, "off")
        self.assertIn("off", title)
        self.assertIn("Settings", advice)

    def test_autostart(self):
        self.assertEqual(psset.autostart_check_result(True)[0], "ok")
        sev, _, advice = psset.autostart_check_result(False)
        self.assertEqual(sev, "off")
        self.assertIn("Settings", advice)

    def test_every_severity_has_a_glyph(self):
        seen = set()
        for args in ((None, None, ""), ("/c", 0, ""), ("/c", 1, "You need to login first"),
                     ("/c", 1, "x"), ("/c", None, "")):
            seen.add(psset.login_check_result(*args)[0])
        for args in ((True, True), (False, True), (False, None), (False, False)):
            seen.add(psset.service_check_result(*args)[0])
        seen |= {psset.autostart_check_result(b)[0] for b in (True, False)}
        self.assertTrue(seen <= set(psset.GLYPHS), seen - set(psset.GLYPHS))


class FailureDescriptions(unittest.TestCase):
    def test_known_classes(self):
        t, a = psset.describe_failure(
            "Fotos/2017", "scan.tif: ValidationError: Failed to generate thumbnails "
            "(use --skip-thumbnails to upload without thumbnails)")
        self.assertIn("Fotos/2017", t)
        self.assertIn("could not be processed", t)
        self.assertIn("retried", a)
        t, _ = psset.describe_failure("Docs", "ENOENT: no such file or directory, statx '/x'")
        self.assertIn("changed while", t)
        t, _ = psset.describe_failure("Docs", "Error: insufficient space / quota exceeded")
        self.assertIn("Not enough space", t)
        t, _ = psset.describe_failure("Docs", "TypeError: fetch failed")
        self.assertIn("Connection problem", t)
        t, _ = psset.describe_failure("Docs", "EACCES: permission denied")
        self.assertIn("No permission", t)
        t, a = psset.describe_failure("Docs", "session expired", login_cmd="/c auth login")
        self.assertIn("session expired", t)
        self.assertIn("/c auth login", a)

    def test_unknown_reason_is_generic(self):
        t, a = psset.describe_failure("Docs", "Error: something went wrong")
        self.assertEqual(t, "Could not upload Docs")
        self.assertIn("retried", a)
        t, _ = psset.describe_failure("Docs", "")
        self.assertEqual(t, "Could not upload Docs")


class Problems(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="proton-sync-root.")

    def titles(self, *args, **kw):
        return [p[1] for p in psset.describe_problems(*args, **kw)]

    def test_quiet_when_nothing_is_wrong(self):
        self.assertEqual(psset.describe_problems(None, [], False, 60, self.root), [])
        self.assertEqual(psset.describe_problems({"state": "watching"}, [], True, 60, self.root), [])

    def test_unconfigured_and_errors(self):
        self.assertEqual(self.titles({"state": "unconfigured"}, [], False, 60, ""), ["Not set up yet"])
        probs = psset.describe_problems({"state": "error", "current": "ECONNRESET"}, [], False, 60, self.root)
        self.assertEqual(probs[0][1], "Proton Drive could not be reached")
        self.assertEqual(probs[0][3], "ECONNRESET")

    def test_missing_sync_folder_wins_over_generic_error(self):
        missing = os.path.join(self.root, "gone")
        probs = psset.describe_problems(
            {"state": "error", "current": "Sync folder not found: " + missing},
            [], False, 60, missing)
        self.assertEqual([p[1] for p in probs], ["The sync folder is missing"])
        self.assertIn("external drive", probs[0][2])

    def test_polling_hint_only_while_running(self):
        probs = psset.describe_problems({"state": "polling"}, [], True, 60, self.root)
        self.assertEqual(probs[0][0], "warn")
        self.assertIn("every 60 minutes", probs[0][1])
        self.assertIn("inotify-tools", probs[0][2])
        self.assertEqual(psset.describe_problems({"state": "polling"}, [], False, 60, self.root), [])

    def test_failed_uploads_are_listed_and_capped(self):
        queue = [{"state": "failed", "path": f"{self.root}/f{i}", "note": "Error: boom"}
                 for i in range(psset.MAX_PROBLEM_ROWS + 3)]
        queue.append({"state": "done", "path": f"{self.root}/ok", "note": ""})
        probs = psset.describe_problems({"state": "idle", "pass_errors": len(queue) - 1},
                                        queue, False, 60, self.root)
        self.assertEqual(len(probs), psset.MAX_PROBLEM_ROWS + 1)
        self.assertEqual(probs[0][1], "Could not upload f0")        # relative name
        self.assertIn("3 more", probs[-1][1])

    def test_unexplained_errors_get_a_generic_note(self):
        probs = psset.describe_problems({"state": "idle", "pass_errors": 2}, [], False, 60, self.root)
        self.assertEqual(len(probs), 1)
        self.assertEqual(probs[0][0], "warn")
        self.assertIn("2 other problems", probs[0][1])
        queue = [{"state": "failed", "path": f"{self.root}/a", "note": "x"}]
        probs = psset.describe_problems({"state": "idle", "pass_errors": 1}, queue, False, 60, self.root)
        self.assertEqual(len(probs), 1)                             # fully explained

    def test_all_severities_have_glyphs(self):
        queue = [{"state": "failed", "path": "/a", "note": "x"}]
        probs = psset.describe_problems({"state": "polling", "pass_errors": 3}, queue, True, 5, "")
        probs += psset.describe_problems({"state": "unconfigured"}, [], False, 5, "")
        self.assertTrue({p[0] for p in probs} <= set(psset.GLYPHS))


class QueueFile(unittest.TestCase):
    def test_parsing_skips_garbage(self):
        os.makedirs(os.path.dirname(psset.QUEUE_FILE), exist_ok=True)
        with open(psset.QUEUE_FILE, "w") as f:
            f.write("done\t/r/a.txt\t\n")
            f.write("failed\t/r/b\tError: boom\n")
            f.write("uploading\t/r/c\n")
            f.write("bogus\t/r/d\t\n")
            f.write("pending\t\t\n")
            f.write("\n")
            f.write("pending\t/r/e\t\n")
        rows = psset.read_queue()
        self.assertEqual([(r["state"], r["path"], r["note"]) for r in rows], [
            ("done", "/r/a.txt", ""), ("failed", "/r/b", "Error: boom"),
            ("uploading", "/r/c", ""), ("pending", "/r/e", "")])

    def test_missing_file_is_empty(self):
        if os.path.exists(psset.QUEUE_FILE):
            os.remove(psset.QUEUE_FILE)
        self.assertEqual(psset.read_queue(), [])

    def test_summary(self):
        def rows(*states):
            return [{"state": s, "path": "/x", "note": ""} for s in states]
        self.assertEqual(psset.queue_summary([], True), "")
        self.assertEqual(psset.queue_summary(rows("done", "done"), False), "2 uploaded")
        self.assertEqual(psset.queue_summary(rows("done", "uploading", "pending"), True), "1 of 3 done")
        self.assertEqual(psset.queue_summary(rows("done", "failed", "done"), False), "2 uploaded · 1 failed")
        self.assertEqual(psset.queue_summary(rows("unchanged", "unchanged", "done"), False),
                         "1 uploaded · 2 unchanged")
        self.assertEqual(psset.queue_summary(rows("unchanged", "pending"), True), "1 of 2 done")

    def test_queue_states_match_the_daemon(self):
        with open(os.path.join(ROOT, "bin", "proton-sync-daemon")) as f:
            src = f.read()
        import re
        emitted = set(re.findall(r"PLAN_STATE\[\$i\]=([a-z]+)", src))
        emitted |= set(re.findall(r'plan_add upload "\$entry" "\$remote_path" ([a-z]+)', src))
        self.assertEqual(emitted, set(psset.QUEUE_STATES))


class LiveFeed(unittest.TestCase):
    def test_read_events_parses_and_skips_garbage(self):
        os.makedirs(os.path.dirname(psset.EVENTS_FILE), exist_ok=True)
        with open(psset.EVENTS_FILE, "w") as f:
            f.write("100\tuploading\t/r/Fotos\t\n")
            f.write("101\tnew\t/r/Fotos/a.jpg\t\n")
            f.write("bad line\n")
            f.write("102\tbogus-kind\t/r/x\t\n")
            f.write("x\tnew\t/r/y\t\n")
            f.write("103\tdone\t/r/Fotos\t2 uploaded · 1 unchanged\n")
        rows = psset.read_events()
        self.assertEqual([(k, p, d) for _, k, p, d in rows], [
            ("uploading", "/r/Fotos", ""), ("new", "/r/Fotos/a.jpg", ""),
            ("done", "/r/Fotos", "2 uploaded · 1 unchanged")])
        self.assertEqual([r[1] for r in psset.read_events(n=1)], ["done"])

    def test_missing_events_file(self):
        if os.path.exists(psset.EVENTS_FILE):
            os.remove(psset.EVENTS_FILE)
        self.assertEqual(psset.read_events(), [])

    def test_describe_event_uses_relative_names_and_known_glyphs(self):
        root = "/h/Desktop"
        sev, text, sec = psset.describe_event("new", "/h/Desktop/Fotos/a.jpg", "", root)
        self.assertEqual((sev, text, sec), ("added", "Added Fotos/a.jpg", ""))
        sev, text, _ = psset.describe_event("updated", "/h/Desktop/n.md", "", root)
        self.assertEqual((sev, text), ("updated", "Updated n.md"))
        sev, text, sec = psset.describe_event("trashed", "/h/Desktop/old.txt", "", root)
        self.assertEqual((sev, text, sec), ("off", "Moved to trash old.txt", ""))
        sec = psset.describe_event("trashed", "/h/Desktop/old.txt", "was already gone from Proton Drive", root)[2]
        self.assertEqual(sec, "was already gone from Proton Drive")
        sev, text, sec = psset.describe_event("failed", "/h/Desktop/Docs", "Error: fetch failed", root)
        self.assertEqual(sev, "fail")
        self.assertIn("Connection problem while uploading Docs", text)
        self.assertEqual(sec, "Error: fetch failed")
        sev, text, sec = psset.describe_event("done", "/h/Desktop/Docs", "3 uploaded · 2 unchanged", root)
        self.assertEqual((sev, text, sec), ("ok", "Docs", "3 uploaded · 2 unchanged"))
        sev, text, _ = psset.describe_event("more", "/h/Desktop/Docs", "120 more files", root)
        self.assertIn("120 more files", text)
        for kind in psset.EVENT_KINDS:
            sev, text, _ = psset.describe_event(kind, "/h/Desktop/x", "d", root)
            self.assertIn(sev, psset.GLYPHS, kind)
            self.assertTrue(text, kind)

    def test_event_kinds_match_the_daemon(self):
        with open(os.path.join(ROOT, "bin", "proton-sync-daemon")) as f:
            src = f.read()
        import re
        emitted = set(re.findall(r"\bevent ([a-z-]+)", src))
        # kinds emitted indirectly: changed_files() prefixes lines with the
        # kind (`sed 's/^/new\t/'`) and emit_file_events() replays them
        emitted |= set(re.findall(r"sed 's/\^/([a-z-]+)\\t/'", src))
        self.assertEqual(emitted, set(psset.EVENT_KINDS),
                         f"daemon/UI disagree: {emitted ^ set(psset.EVENT_KINDS)}")

    def test_state_detail_shows_current_file(self):
        root = "/h/Desktop"
        d = psset.SettingsWindow._state_detail(
            "syncing", {"current": "/h/Desktop/Fotos/2017",
                        "file": "/h/Desktop/Fotos/2017/sub/IMG_1.jpg"}, root)
        self.assertEqual(d, "Uploading Fotos/2017 · sub/IMG_1.jpg")
        d = psset.SettingsWindow._state_detail(
            "syncing", {"current": "/h/Desktop/a.txt", "file": "/h/Desktop/a.txt"}, root)
        self.assertEqual(d, "Uploading a.txt")
        self.assertEqual(psset.SettingsWindow._state_detail("syncing", {}, root), "Preparing…")


class Summaries(unittest.TestCase):
    def test_pass_summary(self):
        self.assertEqual(psset.pass_summary({}), "nothing new to upload")
        self.assertEqual(psset.pass_summary({}, in_progress=True), "no new files so far")
        s = psset.pass_summary({"pass_items": 12, "pass_bytes": 2048, "pass_trashed": 0,
                                "pass_errors": 2, "pass_started": 0})
        self.assertEqual(s, "12 files · 2.0 KiB · 2 problems")
        s = psset.pass_summary({"pass_items": 1, "pass_bytes": 0, "pass_trashed": 1,
                                "pass_started": time.time()})
        self.assertTrue(s.startswith("1 file · 1 moved to trash · started "), s)

    def test_total_summary(self):
        self.assertEqual(psset.total_summary({}), "No sync finished yet")
        s = psset.total_summary({"passes_done": 2, "total_items": 10, "total_bytes": 1024,
                                 "total_trashed": 0, "total_errors": 1})
        self.assertEqual(s, "2 syncs · 10 files · 1.0 KiB · 1 problem")


class FmtTime(unittest.TestCase):
    def test_formats(self):
        import re
        self.assertEqual(psset.fmt_time(0), "—")
        self.assertEqual(psset.fmt_time(None), "—")
        self.assertRegex(psset.fmt_time(time.time()), r"^\d\d:\d\d$")
        self.assertRegex(psset.fmt_time(time.time() - 3 * 86400), r"^[A-Z][a-z]{2} \d{1,2}, \d\d:\d\d$")


class StateCoverage(unittest.TestCase):
    def test_every_daemon_state_has_ui_text(self):
        daemon_states = {"syncing", "debouncing", "watching", "polling",
                         "idle", "stopped", "logged-out", "unconfigured",
                         "error"}
        self.assertTrue(daemon_states <= set(psset.STATE_TEXT.keys()))

    def test_daemon_actually_emits_only_known_states(self):
        with open(os.path.join(ROOT, "bin", "proton-sync-daemon")) as f:
            src = f.read()
        import re
        emitted = set(re.findall(r"write_status ([a-z-]+)", src))
        self.assertTrue(
            emitted <= set(psset.STATE_TEXT.keys()),
            f"daemon emits states without UI text: "
            f"{emitted - set(psset.STATE_TEXT.keys())}")


if __name__ == "__main__":
    unittest.main(verbosity=1)
