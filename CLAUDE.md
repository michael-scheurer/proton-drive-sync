# proton-drive-sync

One-way sync of a local folder to Proton Drive on Linux. Bash daemon +
GTK3/Python settings app + systemd user service, packaged for local install
and as a snap. All Proton communication goes through Proton's own
`proton-drive` CLI binary, which is **not** in this repo (>100 MB, Proton's
license) — it must sit at the repo root or be pointed to via
`PROTON_DRIVE_CLI` in the config.

## Layout

| Path | What it is |
| --- | --- |
| `bin/proton-sync-daemon` | Sync engine (bash). Sourceable for unit tests — `main` is guarded. |
| `bin/proton-sync-settings` | GTK3 settings + activity UI (Python, PyGObject, no build step). |
| `bin/proton-sync-reconcile` | One-off "make Proton Drive match the folder": folder-by-folder compare, trash-only, dry run by default (Python, stdlib). |
| `install-local.sh` | Per-user install: `~/.local/bin`, launcher, systemd unit, apt deps. |
| `snap/snapcraft.yaml` | Snap package (Ubuntu App Center). |
| `tests/run-tests.sh` | Whole test suite (bash daemon tests + `test-settings.py` + `test-reconcile.py`). Run before every PR. |
| `tests/check-no-secrets.sh` | Secret/personal-data scanner; wired as pre-commit hook. |

Runtime files (never committed): config in `~/.config/proton-sync/`
(`config` is shell-sourceable `KEY='VALUE'`, `excludes.list` one absolute
path per line); state in `~/.local/state/proton-sync/` (`sync.log`,
`status.json` for the UI, `queue.tsv` = the current/last pass's upload
list, `events.tsv` = live feed, `history.jsonl` one line per pass,
`manifest.txt` + `manifest.roots` for deletion tracking, `last-sync-stamp`
+ `prev-sync-stamp` for change detection / "updated since last pass",
`trigger/sync-now` = "sync now" request from the UI,
`reconcile-trashed.txt` = undo record of the reconcile tool, lock + pid
files).

## Commands

```bash
tests/run-tests.sh                 # full suite, sandboxed, no network
tests/run-tests.sh <test_name>     # single bash test
tests/check-no-secrets.sh --all    # secret scan over the whole tree
bin/proton-sync-daemon --once      # one sync pass against the real config
git config core.hooksPath .githooks   # once per clone: enable pre-commit scan
```

There is no build step. Deploying locally = `install -Dm755 bin/* ~/.local/bin/`
then `systemctl --user restart proton-sync`.

## Architecture notes

- **One-way sync.** Upload only. `filesystem upload -d merge -f replace`;
  the CLI dedups unchanged files by content. Never add download/overwrite
  logic over the local tree.
- **Deletion sync is opt-in** (`SYNC_DELETES='true'`). Implemented via a
  local manifest diff (`manifest.txt` vs current tree), not by listing the
  remote. Deletions go to Proton **trash** (`filesystem trash`), never hard
  delete. Three invariants the tests enforce: no manifest → no trash;
  newly-excluded-but-present paths are never trashed; a trashed parent
  covers its children.
- **Excludes**: directories containing an excluded descendant are walked
  and recreated remotely folder-by-folder; everything else uploads
  wholesale.
- **A pass is planned, then run.** `plan_dir` builds the ordered list of
  upload units (top-level entries, or children of folders with excludes)
  and `run_plan` executes it. The plan is written to `queue.tsv`
  (`<pending|uploading|done|failed|unchanged>\t<local path>\t<reason>`)
  after every change — that is what the Activity tab's "Files" list shows.
- **Quick passes are incremental** (`decide_unit`): `synced.tsv` remembers
  per unit the pass stamp of its last successful upload (written after
  every unit, so an interrupted pass resumes). A unit with nothing newer
  than that (`find -newermt`, directories included — a folder's mtime
  changes when entries are added/removed/renamed) is `unchanged` and never
  handed to the CLI. A unit with a few changes (≤ `PARTIAL_MAX`, default
  20) uploads only those items, each into its remote parent: changed files
  individually, new entries collapsed to their highest ancestor the
  previous manifest does not know (`unknown_ancestor`), uploaded
  wholesale. More changes, a unit never uploaded, or a failed partial
  upload → the whole unit goes to the CLI as before. A **full check**
  (`PASS_MODE=full`: every `FULL_CHECK_INTERVAL` seconds, default 24 h;
  trigger file content `full`; `--once --full`; no `synced.tsv`; changed
  folder pair) hands everything to the CLI, whose content dedup catches
  what mtimes cannot (files copied with preserved timestamps). The
  inotify wait uses `-t` so the full check fires on time; `status.json`
  carries `mode` so the UI can say "Full check".
- **Upload retries**: a failed unit is retried once for the two known
  fixable classes — thumbnail generation refused (TIFF, macOS `._` files →
  retry with `--skip-thumbnails`) and a file vanishing mid-upload (`ENOENT`
  → retry after `RETRY_DELAY`). Anything else fails once; the reason goes
  into `queue.tsv` and the UI maps it to plain language (`FAILURE_RULES`).
- **Live feed** (`events.tsv`, `<epoch>\t<kind>\t<path>\t<detail>`): the
  CLI never prints file names while it works (`--verbose` logs only node
  ids; the summary lists only *skipped* files), so the daemon derives them:
  files in a unit that are not in the previous pass's manifest → `new`,
  modified since `prev-sync-stamp` → `updated` (capped at 500 per unit, then
  one `more` event; nothing when the CLI reported 0 items uploaded). The
  list is computed *before* the upload so the `uploading` event can carry
  "12 new · 3 updated". While a folder uploads, `run_cli_upload` samples
  `/proc/<cli pid>/fd` for the local file being read and puts it in
  `status.json` as `file` — this only catches files the CLI holds open
  for a while (large ones); small files slip between samples. Event kinds
  live in `EVENT_KINDS` in the settings app and a test cross-checks every
  `event <kind>` call in the daemon against it. The UI shows the feed as
  the "Live" toggle of the Files section, newest first.
- **Reconcile tool** (`bin/proton-sync-reconcile`): compares local vs.
  remote folder by folder (`filesystem list -j`, parallel), trashes
  remote-only entries as whole subtrees with `--apply`, reports local-only
  (the daemon uploads those), type mismatches, unreadable names, shared
  items (skipped unless `--include-shared`: a share link would die) and
  folders it could not list (nothing beneath them is touched; exit 2).
  Every trashed path is appended to `reconcile-trashed.txt` for
  `filesystem restore`. `--save-plan F` writes the result as JSON and
  `--apply-plan F` trashes from it later without a second walk, skipping
  anything that exists locally again. Safe to run while the daemon is
  syncing, but keep `--jobs` at 2: the API answered 429 with more.
- **Config is re-read before every pass** (`load_config`), so Save in the
  app applies without a service restart. The app then touches the trigger
  file to start a pass right away.
- **"Sync now" never kills the daemon.** The UI creates
  `trigger/sync-now`; the daemon watches that directory (inotify branch
  adds it to the watch list; poll branch checks every `TRIGGER_TICK`s) and
  runs a pass without the settle delay. With no daemon running the UI
  falls back to `--once`.
- **Edits made during a pass are caught**: `wait_for_change` first checks
  `anything_changed` against the stamp before blocking on inotify.
- **Data-safety guards around deletions** (all tested):
  - missing sync folder (unplugged drive, renamed) → the pass is skipped
    with state `error`, the daemon waits for the folder to return;
  - sync folder empty *and* on another filesystem than last time
    (unmounted mount point) → nothing is trashed, manifest kept;
  - local/remote folder pair changed since the manifest was written
    (`manifest.roots`) → deletion tracking restarts, nothing is trashed.
- **Change detection**: `inotifywait` when installed, else mtime polling
  (`find -newer` against a stamp file), plus a settle delay.
- **Status for the UI**: the daemon writes `status.json` on every state
  change/upload and appends to `history.jsonl` after each pass. UI states
  must exist in `STATE_TEXT` in the settings app — a test cross-checks
  every `write_status` call in the daemon against it; another checks the
  `PLAN_STATE` values against `QUEUE_STATES`.
- **Full checks are invisible as a concept in the UI**: one "Sync now"
  button, the daemon picks the mode; the state line only adds "Checking
  all files ·" while a full pass runs, and Settings says "Verify all files
  every N hours". Trigger content `full` and `--once --full` remain for
  power users.
- **A trash target that is already gone** (`Node not found`, e.g. deleted
  by hand in Proton Drive) is not an error: logged, `trashed` event with a
  note, children skipped.
- **Activity tab layout** (top to bottom): live state + "Sync now";
  Checks (login via `filesystem list /`, service via the lock file,
  autostart via `systemctl --user is-enabled` / the snap autostart file);
  Needs attention (`describe_problems`: plain-language problem + fix, one
  row per failed unit, polling fallback hint, missing folder …); Files
  (`queue.tsv` as a tree view); History (chart); Technical log in a
  collapsed expander with "Open full log". Keep technical detail out of
  everything above the expander.
- **`POLL_INTERVAL` is seconds in the config** (the daemon sleeps on it);
  the UI shows and edits minutes (`poll_minutes_from_config` /
  `poll_minutes_to_config`).

## Gotchas (learned the hard way)

- **Remote paths are namespaced.** The CLI's root is `/my-files`,
  `/photos`, `/albums`, `/trash`, … User files go under `/my-files/...`.
  Daemon and UI auto-prefix `/my-files` — keep that behavior.
- **The CLI session lives in the system keyring** (libsecret via D-Bus),
  not in a dotfile. Consequences: the snap needs the
  `password-manager-service` interface (not auto-connected), and any
  environment without a session D-Bus can't authenticate.
- **`cli | grep -q` under `set -o pipefail` is a trap**: the CLI exits
  non-zero when logged out, so the pipeline "fails" even when grep matched.
  Capture output into a variable instead of piping.
- **Don't trust this repo's dev terminal environment**: a VS Code snap
  shell exports `SNAP=/snap/code/...`, `GTK_*`, `XDG_*` overrides that
  break GTK apps and hide the CLI session. The settings app detects
  "am I the snap" by checking its own path is under `$SNAP` — plain
  `"SNAP" in os.environ` is wrong here.
- **Photos are separate from Drive files.** `photo upload` flattens into
  Proton Photos and dedups by content ("skipped" in its summary means
  "already present", not an error).
- **The chart needs `python3-gi-cairo`** (GTK↔cairo bridge). The UI
  degrades to a hint label without it; keep it that way.
- The daemon exits 0 (with a status state) when unconfigured/logged out so
  systemd's `Restart=always` retry loop stays quiet and self-heals.
- **CLI flags**: `-v` is *version*, not verbose. `--verbose` exists but
  logs only encrypted node ids — useless for file names. `filesystem list`
  is non-recursive; `-j` gives JSON with `name.value`, `type`
  (`file|folder`), `isShared`, `isSharedByUrl`, `totalStorageSize`
  (encrypted size, not comparable to local).
- **`filesystem list` can be stale right after a change made by another
  CLI process** (local cache in `~/.cache/proton-drive-cli/`). Verify a
  trash with `filesystem list /trash` or `filesystem info PATH` ("Node not
  found" = gone), or list again a little later.
- **Running the CLI from a VS Code snap terminal fails with "You need to
  login first"** even when logged in — the snap env hides the keyring. Use
  `env -i HOME=… PATH=/usr/bin:/bin XDG_RUNTIME_DIR=/run/user/$(id -u)
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus` for manual
  CLI runs, the reconcile tool, and GTK screenshots.
- **The dev shell aliases `find` to bfs**; scripts and the systemd service
  get GNU find (`/usr/bin/find`). Test `find` features in a script, not at
  the prompt. The daemon sticks to what both accept (integer `-newermt
  @epoch`, `-newer`, `-prune`, `-print0`).
- **Test hooks are env vars**, not config: `LOCK_WAIT`, `RETRY_DELAY`,
  `TRIGGER_TICK`, `SAMPLE_INTERVAL`, `PARTIAL_MAX`, `FS_ID_OVERRIDE`
  (filesystem id of the sync folder). The
  suite's stub CLI fakes outcomes via `FAKE_*` vars and watch-mode tests
  swap in a fake `inotifywait` via `PATH` (`use_polling` /
  `use_fake_inotify`). Real inotify-tools may be absent on the dev box —
  the inotify branch is only exercised through the fake.

## Conventions

- Bash: `set -uo pipefail`, no external deps beyond coreutils/awk/grep;
  keep everything sourceable-safe for the tests.
- Python: stdlib + PyGObject only, GTK 3, no pip packages.
- Every behavior change gets a test in `tests/run-tests.sh` (pattern:
  sandbox + stub CLI recording its calls to `calls.log`).
- Nothing personal in the repo: no emails, no absolute `/home/<user>`
  paths, no tokens — the pre-commit scanner enforces this; don't bypass it
  with `--no-verify`.
- The `proton-drive` binary is gitignored. Never `git add -f` it.
