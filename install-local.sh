#!/usr/bin/env bash
#
# install-local.sh — installs Proton Sync (unofficial) for the current user,
# without snap:
#
#   * proton-sync-daemon + proton-sync-settings  -> ~/.local/bin
#   * app icon + launcher ("Proton Sync")        -> ~/.local/share
#   * systemd user service (starts at login)
#   * inotify-tools via apt (asks for sudo; optional)
#   * an initial config if none exists yet
#
# Safe to re-run: it overwrites the installed files with the current versions
# and leaves an existing configuration untouched.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/applications"
ICON_DIR="$HOME/.local/share/icons/hicolor/scalable/apps"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/proton-sync"
UNIT_FILE="$HOME/.config/systemd/user/proton-sync.service"

say() { printf '\n==> %s\n' "$*"; }

# 1 · files -------------------------------------------------------------
say "Installing programs to $BIN_DIR"
install -Dm755 "$HERE/bin/proton-sync-daemon"   "$BIN_DIR/proton-sync-daemon"
install -Dm755 "$HERE/bin/proton-sync-settings" "$BIN_DIR/proton-sync-settings"
install -Dm755 "$HERE/bin/proton-sync-reconcile" "$BIN_DIR/proton-sync-reconcile"

say "Installing icon and app launcher"
install -Dm644 "$HERE/snap/gui/proton-sync.svg" "$ICON_DIR/proton-sync.svg"
install -d "$APP_DIR"
cat > "$APP_DIR/proton-sync.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Proton Sync
GenericName=Folder synchronisation
Comment=Keep a local folder synced to Proton Drive (unofficial)
Exec=$BIN_DIR/proton-sync-settings
Icon=proton-sync
Terminal=false
Categories=Utility;Network;FileTransfer;
Keywords=proton;drive;sync;backup;cloud;
EOF
update-desktop-database "$APP_DIR" 2>/dev/null || true
gtk-update-icon-cache -f "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

# 2 · initial configuration --------------------------------------------
if [[ ! -f "$CONFIG_DIR/config" ]]; then
  say "Writing initial configuration (sync $HOME/Desktop -> /my-files/Desktop)"
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_DIR/config" <<EOF
LOCAL_ROOT='$HOME/Desktop'
REMOTE_ROOT='/my-files/Desktop'
POLL_INTERVAL='300'
DEBOUNCE='30'
PROTON_DRIVE_CLI='$HERE/proton-drive'
EOF
  {
    echo "# Folders excluded from sync (absolute paths, one per line)."
    echo "$HERE"
  } > "$CONFIG_DIR/excludes.list"
else
  say "Existing configuration found — leaving it untouched"
fi

# 3 · background service (old step 3) -----------------------------------
say "Installing systemd user service"
mkdir -p "$(dirname "$UNIT_FILE")"
cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Proton Drive folder sync (unofficial)
After=network-online.target

[Service]
Type=simple
ExecStart=$BIN_DIR/proton-sync-daemon
Restart=always
RestartSec=120

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now proton-sync.service
echo "Service enabled. (It waits quietly until you are logged in to Proton Drive.)"

# 4 · inotify-tools (old step 4) -----------------------------------------
NEED_PKGS=()
command -v inotifywait >/dev/null 2>&1 || NEED_PKGS+=(inotify-tools)
python3 -c 'import gi; gi.require_foreign("cairo")' 2>/dev/null || NEED_PKGS+=(python3-gi-cairo)
if [[ ${#NEED_PKGS[@]} -eq 0 ]]; then
  say "inotify-tools and python3-gi-cairo already installed"
elif command -v apt-get >/dev/null 2>&1; then
  say "Installing ${NEED_PKGS[*]} (needs sudo) — for instant change detection and the activity chart"
  if sudo apt-get install -y "${NEED_PKGS[@]}"; then
    systemctl --user restart proton-sync.service || true
  else
    echo "Could not install ${NEED_PKGS[*]} — sync falls back to polling; the activity chart needs python3-gi-cairo."
  fi
else
  say "apt-get not found — skipping ${NEED_PKGS[*]}"
fi

# 5 · summary -------------------------------------------------------------
LOGIN_HINT=""
if ! "$HERE/proton-drive" filesystem list / >/dev/null 2>&1; then
  LOGIN_HINT="
NEXT STEP — log in to Proton Drive once:
    $HERE/proton-drive auth login
The background service picks it up automatically within ~2 minutes."
fi

cat <<EOF

──────────────────────────────────────────────────────────────
Proton Sync installed ✓

  • Look for "Proton Sync" in your app grid to change settings.
  • Background service:   systemctl --user status proton-sync
  • Log file:             ~/.local/state/proton-sync/sync.log
$LOGIN_HINT
──────────────────────────────────────────────────────────────
EOF
