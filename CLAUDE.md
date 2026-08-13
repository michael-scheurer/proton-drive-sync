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
| `install-local.sh` | Per-user install: `~/.local/bin`, launcher, systemd unit, apt deps. |
| `snap/snapcraft.yaml` | Snap package (Ubuntu App Center). |
| `tests/run-tests.sh` | Whole test suite (bash + Python). Run before every PR. |
| `tests/check-no-secrets.sh` | Secret/personal-data scanner; wired as pre-commit hook. |

Runtime files (never committed): config in `~/.config/proton-sync/`
(`config` is shell-sourceable `KEY='VALUE'`, `excludes.list` one absolute
path per line); state in `~/.local/state/proton-sync/` (`sync.log`,
`status.json` for the UI, `history.jsonl` one line per pass,
`manifest.txt` for deletion tracking, lock + pid files).

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
- **Change detection**: `inotifywait` when installed, else mtime polling
  (`find -newer` against a stamp file), plus a settle delay.
- **Status for the UI**: the daemon writes `status.json` on every state
  change/upload and appends to `history.jsonl` after each pass. UI states
  must exist in `STATE_TEXT` in the settings app — a test cross-checks
  every `write_status` call in the daemon against it.

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
