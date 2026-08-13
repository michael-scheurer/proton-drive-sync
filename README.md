# proton-drive-sync

Keeps a folder on your Linux machine synced to Proton Drive.

Proton doesn't ship a Linux desktop client for Drive, so this fills the gap
with three small pieces: a bash daemon that watches a folder and uploads
changes, a little GTK app to configure it and watch it work, and packaging
so it can be installed like a normal application.

This is a community project. It is **not** affiliated with or endorsed by
Proton AG.

## What it does

- Uploads a folder of your choice to Proton Drive and keeps it up to date.
  Changes are detected instantly (inotify) or by periodic polling.
- Skips files that haven't changed, replaces files that have, merges
  folders. Uploads only — nothing is ever downloaded over your local files.
- Optionally mirrors deletions: delete a file locally and it moves to the
  Proton Drive **trash** (not gone — you can restore it there). This is off
  by default; turn it on in the settings app if you want it.
- Lets you exclude subfolders you don't want synced.
- Shows you what's happening: live status, counters, a small chart of
  recent sync passes, and the log, all in the settings app's Activity tab.

What it deliberately does not do: two-way sync. Your Proton Drive is
treated as the backup of your folder, never the other way around.

## What you need

- Linux with systemd (developed and tested on Ubuntu 24.04)
- The Proton Drive CLI binary (see next section)
- `inotify-tools` and `python3-gi-cairo` — the installer takes care of both

## About the Proton Drive CLI

All actual communication with Proton is done by Proton's own Drive CLI/SDK
binary. It is **not included in this repository** — it's over 100 MB and it
is Proton's software under Proton's license, which is theirs to grant, not
ours. Licensing for everything in this repo (MIT, see below) covers our
code only.

Get the CLI from Proton (it ships with their Drive SDK), name it
`proton-drive`, and either place it in the folder you cloned this repo
into, or point the `PROTON_DRIVE_CLI` entry in
`~/.config/proton-sync/config` at wherever you keep it.

## Install

```bash
git clone git@github.com:michael-scheurer/proton-drive-sync.git
cd proton-drive-sync
# put the proton-drive binary here (see above)
./install-local.sh
./proton-drive auth login
```

The installer puts the two programs in `~/.local/bin`, adds a "Proton Sync"
launcher to your app grid, sets up a systemd user service that starts at
login, and installs the two apt packages if they're missing (it asks for
sudo once for that).

After `auth login` the service picks the session up on its own within a
couple of minutes. Open **Proton Sync** from the app grid to choose which
folder to sync, exclude subfolders, and flip the deletion-sync switch if
you want deletions mirrored.

Default setup: your `~/Desktop` folder syncs to `/my-files/Desktop` on
Proton Drive. Change both in the settings app.

## Day-to-day

You shouldn't have to think about it. If you want to check on it anyway:

- The **Activity** tab in the settings app shows the live state, what's
  currently uploading, and the recent history.
- `systemctl --user status proton-sync` tells you whether the service runs.
- The log lives at `~/.local/state/proton-sync/sync.log`.

A note on the first sync: it uploads everything, so depending on folder
size and your upstream bandwidth it can take hours or days. Later passes
only transfer what changed.

## How deletion sync works (when enabled)

After each pass the daemon records what exists locally. On the next pass,
anything that disappeared from that list — and is really gone from disk —
is moved to the Proton Drive trash. Three safety properties:

1. Files are trashed, never hard-deleted. Restore them from the Proton
   Drive trash if you change your mind.
2. Turning the option on only affects deletions from that moment forward.
   Anything you deleted before is left alone.
3. Excluding a folder never deletes it remotely — exclusion just stops
   syncing it.

## Running the tests

```bash
tests/run-tests.sh
```

The suite runs the daemon against a stub CLI in a sandbox (no network, no
real account) and covers uploads, excludes, the remote path handling,
status reporting, deletion propagation and its safety rules, locking, and
the secret scanner described below.

## Contributing

Before your first commit, enable the hooks:

```bash
git config core.hooksPath .githooks
```

That wires up a pre-commit check (`tests/check-no-secrets.sh`) which blocks
commits containing private keys, tokens, passwords, e-mail addresses,
absolute home paths, the `proton-drive` binary, or anything else that looks
like it shouldn't be public. You can run it over the whole tree yourself
with `tests/check-no-secrets.sh --all`.

Please make sure `tests/run-tests.sh` passes before opening a pull request.

## Snap package

There's a snapcraft setup under `snap/` for building an Ubuntu App Center
package. Building requires placing the `proton-drive` binary in the repo
root first (the snap bundles it, so check Proton's redistribution terms
before publishing the result — and reconsider the snap's name, since
"Proton" is Proton AG's trademark). Details and the smoke-test checklist
are in the comments of `snap/snapcraft.yaml`.

```bash
snapcraft
sudo snap install --dangerous ./proton-sync_0.2.0_amd64.snap
sudo snap connect proton-sync:password-manager-service
```

The last line matters: the CLI keeps its session in the system keyring, and
that interface isn't connected automatically.

## License

Everything in this repository is MIT licensed — use it, change it, sell
it, no strings attached. See [LICENSE](LICENSE).

The Proton Drive CLI binary is not part of this repository and stays under
Proton's own license.
