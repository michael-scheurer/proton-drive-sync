#!/usr/bin/env python3
"""Tests for proton-sync-reconcile against a fake proton-drive CLI.

The fake serves `filesystem list -j` from a directory tree that stands in
for Proton Drive, records every call, and fakes failures via FAKE_* vars.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(ROOT, "bin", "proton-sync-reconcile")

FAKE_CLI = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write(" ".join(args) + "\n")
remote = os.environ["FAKE_REMOTE"]
if args[:2] == ["filesystem", "list"]:
    path = args[-1]
    if path in os.environ.get("FAKE_LIST_FAIL", "").split(":"):
        print("TypeError: fetch failed", file=sys.stderr); sys.exit(1)
    d = os.path.join(remote, path.lstrip("/"))
    if not os.path.isdir(d):
        print("Node not found: " + path.rsplit("/", 1)[-1]); sys.exit(1)
    shared = set(os.environ.get("FAKE_SHARED", "").split(":")) - {""}
    out = []
    for n in sorted(os.listdir(d)):
        p = path + "/" + n
        out.append({"name": {"ok": True, "value": n},
                    "type": "folder" if os.path.isdir(os.path.join(d, n)) else "file",
                    "isShared": p in shared, "isSharedByUrl": False})
    if path in os.environ.get("FAKE_UNREADABLE", "").split(":"):
        out.append({"name": {"ok": False}, "type": "file"})
    print(json.dumps(out)); sys.exit(0)
if args[:2] == ["filesystem", "trash"]:
    bad = set(os.environ.get("FAKE_TRASH_FAIL", "").split(":")) - {""}
    rc = 0
    for p in args[2:]:
        if p in bad:
            print("Node not found: " + p); rc = 1
        else:
            print("✅ " + p)
    sys.exit(rc)
sys.exit(0)
'''


class ReconcileTest(unittest.TestCase):
    def setUp(self):
        self.sb = tempfile.mkdtemp(prefix="proton-sync-reconcile.")
        self.local = os.path.join(self.sb, "local")
        self.remote = os.path.join(self.sb, "remote", "my-files", "Test")
        self.state = os.path.join(self.sb, "state", "proton-sync")
        cfgdir = os.path.join(self.sb, "config", "proton-sync")
        os.makedirs(self.local); os.makedirs(self.remote); os.makedirs(cfgdir)
        self.cli = os.path.join(self.sb, "cli")
        with open(self.cli, "w") as f:
            f.write(FAKE_CLI)
        os.chmod(self.cli, 0o755)
        with open(os.path.join(cfgdir, "config"), "w") as f:
            f.write(f"LOCAL_ROOT='{self.local}'\nREMOTE_ROOT='/my-files/Test'\n"
                    f"PROTON_DRIVE_CLI='{self.cli}'\nSYNC_DELETES='true'\n")
        self.excludes_file = os.path.join(cfgdir, "excludes.list")
        self.env = dict(os.environ,
                        XDG_CONFIG_HOME=os.path.join(self.sb, "config"),
                        XDG_STATE_HOME=os.path.join(self.sb, "state"),
                        FAKE_LOG=os.path.join(self.sb, "calls.log"),
                        FAKE_REMOTE=os.path.join(self.sb, "remote"))

    # -- helpers
    def mk(self, root, *rels):
        """Create files (no trailing slash) or folders (trailing slash)."""
        for rel in rels:
            p = os.path.join(root, rel.rstrip("/"))
            if rel.endswith("/"):
                os.makedirs(p, exist_ok=True)
            else:
                os.makedirs(os.path.dirname(p), exist_ok=True)
                with open(p, "w") as f:
                    f.write("x")

    def run_tool(self, *flags, **env):
        e = dict(self.env, **env)
        r = subprocess.run([TOOL, *flags], capture_output=True, text=True, env=e)
        return r.returncode, r.stdout + r.stderr

    def calls(self):
        try:
            with open(self.env["FAKE_LOG"]) as f:
                return f.read().splitlines()
        except FileNotFoundError:
            return []

    def trashed(self):
        return [l.split(" ", 2)[2:] and l for l in self.calls() if l.startswith("filesystem trash")]

    def trash_targets(self):
        out = []
        for l in self.calls():
            if l.startswith("filesystem trash "):
                out.extend(l[len("filesystem trash "):].split(" /my-files/"))
        return [t if t.startswith("/my-files/") else "/my-files/" + t for t in out]

    # -- tests
    def test_dry_run_reports_but_never_trashes(self):
        self.mk(self.local, "keep.txt")
        self.mk(self.remote, "keep.txt", "gone.txt", "Gone Folder/deep/x.txt")
        rc, out = self.run_tool()
        self.assertEqual(rc, 0, out)
        self.assertIn("Would move to trash (2", out)
        self.assertIn("/my-files/Test/gone.txt", out)
        self.assertIn("/my-files/Test/Gone Folder/", out)
        self.assertFalse(any(c.startswith("filesystem trash") for c in self.calls()))

    def test_apply_trashes_remote_only_as_whole_subtrees(self):
        self.mk(self.local, "keep.txt", "Both/same.txt")
        self.mk(self.remote, "keep.txt", "Both/same.txt", "Both/old.txt",
                "Gone Folder/deep/x.txt", "Gone Folder/deep/y.txt")
        rc, out = self.run_tool("--apply")
        self.assertEqual(rc, 0, out)
        targets = self.trash_targets()
        self.assertEqual(sorted(targets),
                         ["/my-files/Test/Both/old.txt", "/my-files/Test/Gone Folder"])
        # the gone folder was never listed (nothing inside it is touched individually)
        self.assertFalse(any("list -j /my-files/Test/Gone Folder" in c for c in self.calls()))
        self.assertIn("Moved to trash: 2", out)
        with open(os.path.join(self.state, "reconcile-trashed.txt")) as f:
            rec = f.read()
        self.assertIn("/my-files/Test/Gone Folder", rec)
        self.assertIn("/my-files/Test/Both/old.txt", rec)

    def test_never_trashes_what_exists_locally(self):
        self.mk(self.local, "a.txt", "Dir/b.txt", "Dir/Sub/c.txt", "Umlaut ä & co/d.txt")
        self.mk(self.remote, "a.txt", "Dir/b.txt", "Dir/Sub/c.txt", "Umlaut ä & co/d.txt")
        rc, out = self.run_tool("--apply")
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.trash_targets(), [])
        self.assertIn("(nothing)", out)

    def test_local_only_is_reported_not_touched(self):
        self.mk(self.local, "new.txt", "New Folder/f.txt")
        rc, out = self.run_tool("--apply")
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.trash_targets(), [])
        self.assertIn("1 folders, 1 files", out)
        self.assertIn(os.path.join(self.local, "New Folder") + "/", out)

    def test_excluded_folders_are_left_alone_on_both_sides(self):
        self.mk(self.local, "Fotos/keep.jpg", "Fotos/Camera Roll/local-only.jpg")
        self.mk(self.remote, "Fotos/keep.jpg", "Fotos/Camera Roll/remote-only.jpg", "Fotos/Camera Roll/also.jpg")
        with open(self.excludes_file, "w") as f:
            f.write(os.path.join(self.local, "Fotos", "Camera Roll") + "\n")
        rc, out = self.run_tool("--apply")
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.trash_targets(), [])
        self.assertIn("Left alone because excluded locally (1)", out)
        self.assertFalse(any("Camera Roll" in c and c.startswith("filesystem list") for c in self.calls()))

    def test_shared_remote_only_is_skipped_unless_asked(self):
        self.mk(self.remote, "Shared Album/x.jpg", "plain-gone.txt")
        shared = "/my-files/Test/Shared Album"
        rc, out = self.run_tool("--apply", FAKE_SHARED=shared)
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.trash_targets(), ["/my-files/Test/plain-gone.txt"])
        self.assertIn("Left alone because shared (1", out)
        os.remove(self.env["FAKE_LOG"])
        rc, out = self.run_tool("--apply", "--include-shared", FAKE_SHARED=shared)
        self.assertIn(shared, self.trash_targets())

    def test_unlistable_folder_blocks_everything_beneath_it(self):
        self.mk(self.local, "Ok/keep.txt", "Flaky/keep.txt")
        self.mk(self.remote, "Ok/keep.txt", "Ok/gone.txt", "Flaky/keep.txt", "Flaky/gone.txt")
        rc, out = self.run_tool("--apply", FAKE_LIST_FAIL="/my-files/Test/Flaky")
        self.assertEqual(rc, 2, out)
        self.assertEqual(self.trash_targets(), ["/my-files/Test/Ok/gone.txt"])
        self.assertIn("Could NOT compare (1", out)
        self.assertIn("/my-files/Test/Flaky", out)
        # retried before giving up
        self.assertGreaterEqual(sum("list -j /my-files/Test/Flaky" in c for c in self.calls()), 2)

    def test_type_mismatch_is_reported_not_touched(self):
        self.mk(self.local, "thing/inner.txt")        # local folder
        self.mk(self.remote, "thing")                 # remote file
        rc, out = self.run_tool("--apply")
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.trash_targets(), [])
        self.assertIn("Type mismatch", out)
        self.assertIn("(remote file, local folder)", out)

    def test_unreadable_names_are_skipped(self):
        self.mk(self.local, "a.txt")
        self.mk(self.remote, "a.txt")
        rc, out = self.run_tool("--apply", FAKE_UNREADABLE="/my-files/Test")
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.trash_targets(), [])
        self.assertIn("Unreadable or unsupported names", out)

    def test_batches_and_isolates_failures(self):
        names = [f"gone-{i:02d}.txt" for i in range(30)]
        self.mk(self.remote, *names)
        bad = "/my-files/Test/gone-07.txt"
        rc, out = self.run_tool("--apply", FAKE_TRASH_FAIL=bad)
        self.assertEqual(rc, 2, out)
        self.assertIn("Moved to trash: 29   failed: 1", out)
        self.assertIn(bad, out)
        trash_calls = [c for c in self.calls() if c.startswith("filesystem trash")]
        self.assertGreaterEqual(len(trash_calls), 2)          # at least two batches
        with open(os.path.join(self.state, "reconcile-trashed.txt")) as f:
            rec = f.read()
        self.assertNotIn(bad, rec)
        self.assertEqual(rec.count("/my-files/Test/gone-"), 29)

    def test_save_plan_then_apply_plan_skips_reappeared_files(self):
        self.mk(self.local, "keep.txt")
        self.mk(self.remote, "keep.txt", "gone.txt", "Gone Folder/x.txt", "back.txt")
        plan = os.path.join(self.sb, "plan.json")
        rc, out = self.run_tool("--save-plan", plan)
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.trash_targets(), [])
        with open(plan) as f:
            data = json.load(f)
        self.assertEqual(sorted(p for p, _ in data["remote_only"]),
                         ["/my-files/Test/Gone Folder", "/my-files/Test/back.txt",
                          "/my-files/Test/gone.txt"])
        os.remove(self.env["FAKE_LOG"])
        self.mk(self.local, "back.txt")          # user re-created it meanwhile
        rc, out = self.run_tool("--apply-plan", plan)
        self.assertEqual(rc, 0, out)
        self.assertEqual(sorted(self.trash_targets()),
                         ["/my-files/Test/Gone Folder", "/my-files/Test/gone.txt"])
        self.assertIn("1 skipped because they exist locally again", out)
        self.assertFalse(any(c.startswith("filesystem list") for c in self.calls()))

    def test_apply_plan_refuses_a_plan_for_other_folders(self):
        plan = os.path.join(self.sb, "plan.json")
        with open(plan, "w") as f:
            json.dump({"local_root": self.local, "remote_root": "/my-files/Other",
                       "remote_only": [["/my-files/Other/x", "file"]]}, f)
        rc, out = self.run_tool("--apply-plan", plan)
        self.assertEqual(rc, 1, out)
        self.assertIn("Cannot use plan", out)
        self.assertEqual(self.calls(), [])

    def test_missing_remote_root_means_everything_is_local_only(self):
        self.mk(self.local, "a.txt", "B/c.txt")
        os.rmdir(self.remote)
        rc, out = self.run_tool("--apply")
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.trash_targets(), [])
        self.assertIn("1 folders, 1 files", out)

    def test_missing_local_root_refuses(self):
        os.rmdir(self.local)
        rc, out = self.run_tool("--apply")
        self.assertEqual(rc, 1)
        self.assertIn("Sync folder not found", out)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main(verbosity=1)
