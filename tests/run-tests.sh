#!/usr/bin/env bash
#
# Test suite for proton-sync. Runs the daemon against a stub proton-drive CLI
# in a throwaway sandbox — no network, no real Proton account, no touching the
# user's real config/state. Finishes with the Python tests for the settings
# app helpers.
#
#   tests/run-tests.sh            run everything
#   tests/run-tests.sh <name>     run a single bash test by function name

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/bin/proton-sync-daemon"
PASSED=0
FAILED=0

# ------------------------------------------------------------- harness ---
pass() { PASSED=$((PASSED + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf 'FAIL %s — %s\n' "$1" "$2"; }

# Fresh sandbox: fake HOME-ish dirs, a local tree, a recording stub CLI.
new_sandbox() {
  SB="$(mktemp -d /tmp/proton-sync-test.XXXXXX)"
  export XDG_CONFIG_HOME="$SB/config"
  export XDG_STATE_HOME="$SB/state"
  export FAKE_LOG="$SB/calls.log"
  export FAKE_MODE=ok
  export LOCK_WAIT=1
  LOCAL="$SB/local"
  STATE="$SB/state/proton-sync"
  mkdir -p "$LOCAL" "$XDG_CONFIG_HOME/proton-sync"
  cat > "$SB/cli" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$FAKE_LOG"
if [[ "${FAKE_MODE:-ok}" == "not-logged-in" && "$1 $2" == "filesystem list" ]]; then
  echo "You need to login first"
  exit 1
fi
if [[ "$1 $2" == "filesystem upload" ]]; then
  echo "Transfer summary:"
  echo "  Uploaded: 2 items (1.00 KiB)"
fi
if [[ "${FAKE_TRASH_FAIL:-0}" == "1" && "$1 $2" == "filesystem trash" ]]; then
  exit 1
fi
exit 0
EOF
  chmod +x "$SB/cli"
}

write_config() {  # extra config lines as arguments
  {
    echo "LOCAL_ROOT='$LOCAL'"
    echo "REMOTE_ROOT='/my-files/Test'"
    echo "PROTON_DRIVE_CLI='$SB/cli'"
    printf '%s\n' "$@"
  } > "$XDG_CONFIG_HOME/proton-sync/config"
}

run_once() { "$DAEMON" --once > "$SB/stdout.log" 2> "$SB/stderr.log"; }
calls()    { cat "$FAKE_LOG" 2>/dev/null || true; }
status_of() { python3 -c "import json,sys; print(json.load(open('$STATE/status.json'))['$1'])"; }
cleanup()  { rm -rf "$SB"; }

# ----------------------------------------------------------- bash tests ---
test_uploads_top_level_entries() {
  new_sandbox
  echo hi > "$LOCAL/a.txt"
  mkdir -p "$LOCAL/sub"; echo x > "$LOCAL/sub/x.txt"
  write_config
  run_once
  if calls | grep -q "filesystem upload -d merge -f replace $LOCAL/a.txt /my-files/Test" \
     && calls | grep -q "filesystem upload -d merge -f replace $LOCAL/sub /my-files/Test"; then
    pass "$FUNCNAME"
  else
    fail "$FUNCNAME" "expected upload calls for a.txt and sub/ (got: $(calls | grep upload))"
  fi
  cleanup
}

test_excluded_folder_is_skipped() {
  new_sandbox
  mkdir -p "$LOCAL/keep" "$LOCAL/secret"
  echo x > "$LOCAL/secret/f.txt"
  write_config
  echo "$LOCAL/secret" > "$XDG_CONFIG_HOME/proton-sync/excludes.list"
  run_once
  if calls | grep -q "upload.*$LOCAL/secret"; then
    fail "$FUNCNAME" "excluded folder was uploaded"
  elif ! grep -q "skip (excluded): $LOCAL/secret" "$STATE/sync.log"; then
    fail "$FUNCNAME" "no skip log line"
  else
    pass "$FUNCNAME"
  fi
  cleanup
}

test_descends_around_nested_exclude() {
  new_sandbox
  mkdir -p "$LOCAL/keep/sub/secret" "$LOCAL/keep/other"
  echo x > "$LOCAL/keep/sub/secret/f.txt"
  echo y > "$LOCAL/keep/sub/sibling.txt"
  write_config
  echo "$LOCAL/keep/sub/secret" > "$XDG_CONFIG_HOME/proton-sync/excludes.list"
  run_once
  if ! calls | grep -q "create-folder /my-files/Test keep"; then
    fail "$FUNCNAME" "ancestor folder not created remotely"
  elif ! calls | grep -q "filesystem upload .* $LOCAL/keep/sub/sibling.txt /my-files/Test/keep/sub"; then
    fail "$FUNCNAME" "sibling of exclude not uploaded"
  elif calls | grep -q "$LOCAL/keep/sub/secret"; then
    fail "$FUNCNAME" "excluded path leaked into CLI calls"
  else
    pass "$FUNCNAME"
  fi
  cleanup
}

test_remote_root_gets_myfiles_prefix() {
  new_sandbox
  echo hi > "$LOCAL/a.txt"
  write_config "REMOTE_ROOT='/Plain'"
  run_once
  if calls | grep -q "filesystem upload .* /my-files/Plain" \
     && ! calls | grep -q "create-folder / my-files"; then
    pass "$FUNCNAME"
  else
    fail "$FUNCNAME" "expected /my-files auto-prefix without creating /my-files itself"
  fi
  cleanup
}

test_nested_remote_root_created_in_order() {
  new_sandbox
  echo hi > "$LOCAL/a.txt"
  write_config "REMOTE_ROOT='/my-files/A/B'"
  run_once
  local seq
  seq="$(calls | grep create-folder | head -2 | tr '\n' '|')"
  if [[ "$seq" == "filesystem create-folder /my-files A|filesystem create-folder /my-files/A B|" ]]; then
    pass "$FUNCNAME"
  else
    fail "$FUNCNAME" "unexpected create-folder sequence: $seq"
  fi
  cleanup
}

test_status_counters_and_valid_json() {
  new_sandbox
  echo a > "$LOCAL/a.txt"
  echo b > "$LOCAL/b.txt"
  write_config
  run_once
  # 2 uploads x stub summary "2 items (1.00 KiB)" = 4 items, 2048 bytes
  if ! python3 -m json.tool "$STATE/status.json" >/dev/null 2>&1; then
    fail "$FUNCNAME" "status.json is not valid JSON"
  elif [[ "$(status_of state)" != "idle" ]]; then
    fail "$FUNCNAME" "final state is $(status_of state), expected idle"
  elif [[ "$(status_of pass_items)" != "4" || "$(status_of pass_bytes)" != "2048" ]]; then
    fail "$FUNCNAME" "counters wrong: items=$(status_of pass_items) bytes=$(status_of pass_bytes)"
  else
    pass "$FUNCNAME"
  fi
  cleanup
}

test_history_line_appended() {
  new_sandbox
  echo a > "$LOCAL/a.txt"
  write_config
  run_once
  local n
  n="$(wc -l < "$STATE/history.jsonl" 2>/dev/null || echo 0)"
  if [[ "$n" == "1" ]] && python3 -c "
import json; r = json.load(open('$STATE/history.jsonl'))
assert r['items'] == 2 and r['bytes'] == 1024 and r['trashed'] == 0 and r['end'] >= r['start']
" 2>/dev/null; then
    pass "$FUNCNAME"
  else
    fail "$FUNCNAME" "history.jsonl missing or wrong ($n lines)"
  fi
  cleanup
}

test_not_logged_in_exits_cleanly() {
  new_sandbox
  echo a > "$LOCAL/a.txt"
  write_config
  export FAKE_MODE=not-logged-in
  run_once
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    fail "$FUNCNAME" "exit code $rc, expected 0"
  elif [[ "$(status_of state)" != "logged-out" ]]; then
    fail "$FUNCNAME" "state $(status_of state), expected logged-out"
  elif calls | grep -q "filesystem upload"; then
    fail "$FUNCNAME" "uploads attempted while logged out"
  else
    pass "$FUNCNAME"
  fi
  cleanup
}

test_unconfigured_exits_cleanly() {
  new_sandbox
  # no config file at all
  run_once
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    fail "$FUNCNAME" "exit code $rc, expected 0"
  elif [[ "$(status_of state)" != "unconfigured" ]]; then
    fail "$FUNCNAME" "state $(status_of state), expected unconfigured"
  else
    pass "$FUNCNAME"
  fi
  cleanup
}

test_deletions_not_propagated_by_default() {
  new_sandbox
  echo a > "$LOCAL/a.txt"
  echo b > "$LOCAL/b.txt"
  write_config
  run_once
  rm "$LOCAL/b.txt"
  run_once
  if calls | grep -q "filesystem trash"; then
    fail "$FUNCNAME" "trash was called although SYNC_DELETES is off"
  else
    pass "$FUNCNAME"
  fi
  cleanup
}

test_deletion_propagated_when_enabled() {
  new_sandbox
  echo a > "$LOCAL/a.txt"
  echo b > "$LOCAL/b.txt"
  write_config "SYNC_DELETES='true'"
  run_once                       # baseline pass — must not trash anything
  if calls | grep -q "filesystem trash"; then
    fail "$FUNCNAME" "baseline pass already trashed something"; cleanup; return
  fi
  rm "$LOCAL/b.txt"
  run_once
  if ! calls | grep -q "filesystem trash /my-files/Test/b.txt"; then
    fail "$FUNCNAME" "expected trash call for b.txt"; cleanup; return
  fi
  if [[ "$(status_of pass_trashed)" != "1" ]]; then
    fail "$FUNCNAME" "pass_trashed=$(status_of pass_trashed), expected 1"; cleanup; return
  fi
  : > "$FAKE_LOG"
  run_once                       # third pass — must not trash again
  if calls | grep -q "filesystem trash"; then
    fail "$FUNCNAME" "trash repeated on a later pass"
  else
    pass "$FUNCNAME"
  fi
  cleanup
}

test_deleted_directory_trashed_once() {
  new_sandbox
  mkdir -p "$LOCAL/dir/deep"
  echo 1 > "$LOCAL/dir/f1.txt"
  echo 2 > "$LOCAL/dir/deep/f2.txt"
  write_config "SYNC_DELETES='true'"
  run_once
  rm -rf "$LOCAL/dir"
  run_once
  local n
  n="$(calls | grep -c 'filesystem trash')"
  if [[ "$n" == "1" ]] && calls | grep -q "filesystem trash /my-files/Test/dir$"; then
    pass "$FUNCNAME"
  else
    fail "$FUNCNAME" "expected exactly 1 trash call for the dir, got $n: $(calls | grep trash)"
  fi
  cleanup
}

test_newly_excluded_path_is_not_trashed() {
  new_sandbox
  mkdir -p "$LOCAL/later-excluded"
  echo x > "$LOCAL/later-excluded/f.txt"
  write_config "SYNC_DELETES='true'"
  run_once
  echo "$LOCAL/later-excluded" > "$XDG_CONFIG_HOME/proton-sync/excludes.list"
  run_once
  if calls | grep -q "filesystem trash"; then
    fail "$FUNCNAME" "excluding a folder caused it to be trashed remotely"
  else
    pass "$FUNCNAME"
  fi
  cleanup
}

test_no_manifest_means_no_trash() {
  new_sandbox
  echo a > "$LOCAL/a.txt"
  write_config "SYNC_DELETES='true'"
  run_once
  rm -f "$STATE/manifest.txt" "$LOCAL/a.txt"
  run_once
  if calls | grep -q "filesystem trash"; then
    fail "$FUNCNAME" "trash called without a previous manifest"
  else
    pass "$FUNCNAME"
  fi
  cleanup
}

test_failed_trash_counts_as_error() {
  new_sandbox
  echo a > "$LOCAL/a.txt"
  echo b > "$LOCAL/b.txt"
  write_config "SYNC_DELETES='true'"
  run_once
  rm "$LOCAL/b.txt"
  export FAKE_TRASH_FAIL=1
  run_once
  unset FAKE_TRASH_FAIL
  if [[ "$(status_of pass_trashed)" == "0" && "$(status_of pass_errors)" == "1" ]] \
     && grep -q "ERROR: trash failed" "$STATE/sync.log"; then
    pass "$FUNCNAME"
  else
    fail "$FUNCNAME" "trashed=$(status_of pass_trashed) errors=$(status_of pass_errors)"
  fi
  cleanup
}

test_second_instance_refuses() {
  new_sandbox
  echo a > "$LOCAL/a.txt"
  write_config
  mkdir -p "$STATE"
  (
    exec 9>"$STATE/daemon.lock"
    flock 9
    sleep 4
  ) &
  local holder=$!
  sleep 0.3
  run_once
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  if grep -q "already running" "$SB/stderr.log" && ! calls | grep -q upload; then
    pass "$FUNCNAME"
  else
    fail "$FUNCNAME" "second instance did not refuse (stderr: $(cat "$SB/stderr.log"))"
  fi
  cleanup
}

# --------------------------------------------- sourced unit-level tests ---
test_parse_uploaded_units() {
  new_sandbox
  write_config
  # shellcheck disable=SC1090
  source "$DAEMON"   # main() is guarded, safe to source
  set +o pipefail    # the daemon's pipefail must not leak into the harness
  local r ok=1
  r="$(parse_uploaded $'Transfer summary:\n  Uploaded: 3 items (2.00 MiB)')"
  [[ "$r" == "3 2097152" ]] || { ok=0; echo "  MiB: got '$r'"; }
  r="$(parse_uploaded $'  Uploaded: 1 items (512 B)')"
  [[ "$r" == "1 512" ]] || { ok=0; echo "  B: got '$r'"; }
  r="$(parse_uploaded $'  Uploaded: 7 items (1.50 GiB)')"
  [[ "$r" == "7 1610612736" ]] || { ok=0; echo "  GiB: got '$r'"; }
  r="$(parse_uploaded 'no summary here')"
  [[ "$r" == "0 0" ]] || { ok=0; echo "  none: got '$r'"; }
  [[ $ok == 1 ]] && pass "$FUNCNAME" || fail "$FUNCNAME" "see lines above"
  cleanup
}

test_json_escape() {
  new_sandbox
  write_config
  # shellcheck disable=SC1090
  source "$DAEMON"
  set +o pipefail
  local r
  r="$(json_escape 'a"b\c')"
  if [[ "$r" == 'a\"b\\c' ]]; then
    pass "$FUNCNAME"
  else
    fail "$FUNCNAME" "got '$r'"
  fi
  cleanup
}

test_build_manifest_prunes_excludes() {
  new_sandbox
  mkdir -p "$LOCAL/in" "$LOCAL/out"
  echo 1 > "$LOCAL/in/f.txt"
  echo 2 > "$LOCAL/out/g.txt"
  write_config
  echo "$LOCAL/out" > "$XDG_CONFIG_HOME/proton-sync/excludes.list"
  # shellcheck disable=SC1090
  source "$DAEMON"
  set +o pipefail
  load_excludes
  local m
  m="$(build_manifest)"
  if grep -q '^in/f.txt$' <<<"$m" && ! grep -q '^out' <<<"$m"; then
    pass "$FUNCNAME"
  else
    fail "$FUNCNAME" "manifest: $m"
  fi
  cleanup
}

# -------------------------------------------------- secret-scanner tests ---
# Each builds a scratch git repo containing a copy of the scanner, stages a
# file, and checks the verdict.
new_git_sandbox() {
  GSB="$(mktemp -d /tmp/proton-sync-sectest.XXXXXX)"
  mkdir -p "$GSB/tests"
  cp "$ROOT/tests/check-no-secrets.sh" "$GSB/tests/"
  git -C "$GSB" init -q
}

test_secret_scanner_blocks_planted_secrets() {
  new_git_sandbox
  local ok=1
# the planted strings are split ('' in the middle) so that this test file
  # itself never contains a secret-shaped literal and stays scan-clean
  printf 'aws_key = "AKIA''IOSFODNN7REALKEY"\n' > "$GSB/config.py"
  printf -- '-----BEGIN RSA'' PRIVATE KEY-----\nabc\n' > "$GSB/server.txt"
  printf 'pass''word = "hunter2"\n' > "$GSB/settings.ini"
  printf 'contact me at somebody''@company-mail.ch\n' > "$GSB/notes.md"
  printf 'LOG=/home/''realuser/.local/state/x.log\n' > "$GSB/paths.sh"
  git -C "$GSB" add -A
  local out
  out="$(cd "$GSB" && tests/check-no-secrets.sh 2>&1)"
  local rc=$?
  [[ $rc -ne 0 ]] || { ok=0; echo "  scanner passed a tree full of secrets"; }
  for want in "AWS key" "private key" "password" "email" "home path"; do
    grep -qi "$want" <<<"$out" || { ok=0; echo "  did not flag: $want"; }
  done
  [[ $ok == 1 ]] && pass "$FUNCNAME" || fail "$FUNCNAME" "see above"
  rm -rf "$GSB"
}

test_secret_scanner_blocks_forbidden_filenames() {
  new_git_sandbox
  local ok=1
  echo "X=1" > "$GSB/.env"
  echo "k" > "$GSB/deploy.pem"
  : > "$GSB/proton-drive"
  git -C "$GSB" add -A -f
  local out
  out="$(cd "$GSB" && tests/check-no-secrets.sh 2>&1)"
  [[ $? -ne 0 ]] || ok=0
  grep -q "forbidden file name: .env" <<<"$out" || { ok=0; echo "  .env not flagged"; }
  grep -q "forbidden file name: deploy.pem" <<<"$out" || { ok=0; echo "  .pem not flagged"; }
  grep -q "proton-drive binary" <<<"$out" || { ok=0; echo "  proton-drive not flagged"; }
  [[ $ok == 1 ]] && pass "$FUNCNAME" || fail "$FUNCNAME" "see above"
  rm -rf "$GSB"
}

test_secret_scanner_passes_clean_files() {
  new_git_sandbox
  cat > "$GSB/clean.sh" <<'EOF'
#!/usr/bin/env bash
# Uses $HOME at runtime, never a literal home path.
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/proton-sync"
echo "see https://github.com/example/repo and git@github.com:example/repo.git"
EOF
  git -C "$GSB" add -A
  if (cd "$GSB" && tests/check-no-secrets.sh >/dev/null 2>&1); then
    pass "$FUNCNAME"
  else
    fail "$FUNCNAME" "clean file was flagged: $(cd "$GSB" && tests/check-no-secrets.sh 2>&1 | head -3)"
  fi
  rm -rf "$GSB"
}

test_secret_scanner_all_mode_scans_repo() {
  # the real repository itself must be clean
  if (cd "$ROOT" && git rev-parse --git-dir >/dev/null 2>&1); then
    if (cd "$ROOT" && tests/check-no-secrets.sh --all >/dev/null 2>&1); then
      pass "$FUNCNAME"
    else
      fail "$FUNCNAME" "repo tree flagged: $(cd "$ROOT" && tests/check-no-secrets.sh --all 2>&1 | head -5)"
    fi
  else
    pass "$FUNCNAME (skipped — not a git repo yet)"
  fi
}

# ------------------------------------------------------------------ run ---
BASH_TESTS=(
  test_uploads_top_level_entries
  test_excluded_folder_is_skipped
  test_descends_around_nested_exclude
  test_remote_root_gets_myfiles_prefix
  test_nested_remote_root_created_in_order
  test_status_counters_and_valid_json
  test_history_line_appended
  test_not_logged_in_exits_cleanly
  test_unconfigured_exits_cleanly
  test_deletions_not_propagated_by_default
  test_deletion_propagated_when_enabled
  test_deleted_directory_trashed_once
  test_newly_excluded_path_is_not_trashed
  test_no_manifest_means_no_trash
  test_failed_trash_counts_as_error
  test_second_instance_refuses
  test_secret_scanner_blocks_planted_secrets
  test_secret_scanner_blocks_forbidden_filenames
  test_secret_scanner_passes_clean_files
  test_secret_scanner_all_mode_scans_repo
  test_parse_uploaded_units
  test_json_escape
  test_build_manifest_prunes_excludes
)

if [[ $# -eq 1 ]]; then
  "$1"
else
  for t in "${BASH_TESTS[@]}"; do "$t"; done
fi

echo
if python3 "$ROOT/tests/test-settings.py"; then
  PY_OK=1
else
  PY_OK=0
fi

echo
echo "bash: $PASSED passed, $FAILED failed; python: $([[ $PY_OK == 1 ]] && echo ok || echo FAILED)"
[[ $FAILED -eq 0 && $PY_OK -eq 1 ]] || exit 1
