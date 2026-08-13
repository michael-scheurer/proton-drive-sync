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
