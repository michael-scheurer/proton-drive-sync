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
# Stub proton-drive: records every call, fakes outcomes via FAKE_* env vars.
echo "$@" >> "$FAKE_LOG"
if [[ "${FAKE_MODE:-ok}" == "not-logged-in" && "$1 $2" == "filesystem list" ]]; then
  echo "You need to login first"
  exit 1
fi
if [[ "$1 $2" == "filesystem upload" ]]; then
  local_path="${@: -2:1}"
  # simulate an edit made while the pass is running (once)
  if [[ -n "${FAKE_TOUCH:-}" && ! -e "$FAKE_TOUCH" ]]; then
    echo late > "$FAKE_TOUCH"
  fi
  [[ -n "${FAKE_SLEEP:-}" ]] && sleep "$FAKE_SLEEP"
  if [[ -n "${FAKE_HOLD_OPEN:-}" && -d "$local_path" ]]; then
    exec 3< "$FAKE_HOLD_OPEN"; sleep "${FAKE_SLEEP:-2}"; exec 3<&-
  fi
  if [[ -n "${FAKE_FAIL_PATH:-}" && "$local_path" == "$FAKE_FAIL_PATH" ]]; then
    echo "Error: something went wrong"
    exit 1
  fi
  if [[ "${FAKE_THUMB_FAIL:-0}" == "1" && " $* " != *" --skip-thumbnails "* ]]; then
    echo "Transfer summary:"
    echo "  Uploaded: 1 items (512 B)"
    echo "  Failed: 1 items"
    echo "  - scan.tif: ValidationError: Failed to generate thumbnails (use --skip-thumbnails to upload without thumbnails): Image: format not supported"
    echo "1 item(s) failed to upload"
    exit 1
  fi
  if [[ "${FAKE_ENOENT_ONCE:-0}" == "1" && ! -e "$FAKE_LOG.enoent" ]]; then
    : > "$FAKE_LOG.enoent"
    echo "Transfer summary:"
    echo "  Uploaded: 0 items (0 B)"
    echo "ENOENT: no such file or directory, statx '$local_path/tmp.part'"
    exit 1
  fi
  echo "Transfer summary:"
  if [[ "${FAKE_NOTHING_NEW:-0}" == "1" ]]; then
    echo "  Uploaded: 0 items (0 B)"
    echo "  Skipped: 1 items"
  else
    echo "  Uploaded: 2 items (1.00 KiB)"
  fi
fi
if [[ "${FAKE_TRASH_FAIL:-0}" == "1" && "$1 $2" == "filesystem trash" ]]; then
  exit 1
fi
if [[ "${FAKE_TRASH_GONE:-0}" == "1" && "$1 $2" == "filesystem trash" ]]; then
  echo "Node not found: ${3##*/}"
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
queue()    { cat "$STATE/queue.tsv" 2>/dev/null || true; }
events()   { cut -f2- "$STATE/events.tsv" 2>/dev/null || true; }   # kind, path, detail

# --- watch-mode harness. The daemon runs in its own process group so that
# stop_watch also takes down whatever it spawned (sleep, fake inotifywait).
start_watch() {
  setsid "$DAEMON" > "$SB/watch.out" 2>&1 &
  WPID=$!
}
stop_watch() {
  kill -TERM -- "-$WPID" 2>/dev/null
  wait "$WPID" 2>/dev/null
}
passes_done() { local n; n="$(grep -c 'sync pass finished' "$STATE/sync.log" 2>/dev/null)"; echo "${n:-0}"; }
wait_for_passes() {  # <n> <timeout seconds>
  local i
  for (( i = 0; i < $2 * 5; i++ )); do
    [[ "$(passes_done)" -ge "$1" ]] && return 0
    sleep 0.2
  done
  return 1
}
# PATH shim that makes the daemon fall back to polling (inotifywait "fails").
use_polling() {
  mkdir -p "$SB/bin-poll"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SB/bin-poll/inotifywait"
  chmod +x "$SB/bin-poll/inotifywait"
  export PATH="$SB/bin-poll:$PATH"
}
# PATH shim simulating inotifywait: exits with the path of the first file
# that shows up in the trigger dir (last argument), or with a path inside the
# watched tree once $SB/inotify-event exists. Records its arguments.
use_fake_inotify() {
  mkdir -p "$SB/bin-inotify"
  cat > "$SB/bin-inotify/inotifywait" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$FAKE_INOTIFY_LOG"
root="${@: -2:1}"; trig="${@: -1}"
for (( i = 0; i < 100; i++ )); do
  f="$(ls -A "$trig" 2>/dev/null | head -n1)"
  if [[ -n "$f" ]]; then echo "$trig/$f"; exit 0; fi
  if [[ -e "$FAKE_INOTIFY_EVENT" ]]; then rm -f "$FAKE_INOTIFY_EVENT"; echo "$root/changed.txt"; exit 0; fi
  sleep 0.2
done
exit 1
EOF
  chmod +x "$SB/bin-inotify/inotifywait"
  export FAKE_INOTIFY_LOG="$SB/inotify.log" FAKE_INOTIFY_EVENT="$SB/inotify-event"
  export PATH="$SB/bin-inotify:$PATH"
}

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

test_remote_copy_already_gone_is_not_an_error() {
  # The user deleted the file in Proton Drive first, then locally: the
  # daemon finds nothing to trash, and that is fine.
  new_sandbox
  echo a > "$LOCAL/a.txt"
  mkdir -p "$LOCAL/dir"; echo b > "$LOCAL/dir/b.txt"; echo c > "$LOCAL/dir/c.txt"
  write_config "SYNC_DELETES='true'"
  run_once
  rm "$LOCAL/a.txt"; rm -r "$LOCAL/dir"
  export FAKE_TRASH_GONE=1
  run_once
  unset FAKE_TRASH_GONE
  if [[ "$(status_of pass_errors)" != "0" || "$(status_of pass_trashed)" != "0" ]]; then
    fail "$FUNCNAME" "errors=$(status_of pass_errors) trashed=$(status_of pass_trashed)"
  elif [[ "$(calls | grep -c 'filesystem trash')" != "2" ]]; then
    fail "$FUNCNAME" "expected 2 trash calls (a.txt, dir — children covered), got: $(calls | grep trash)"
  elif ! grep -q "already gone from Proton Drive" "$STATE/sync.log"; then
    fail "$FUNCNAME" "not logged"
  elif ! events | grep -q $'^trashed\t'"$LOCAL/a.txt"$'\twas already gone'; then
    fail "$FUNCNAME" "no feed entry: $(events | grep trash)"
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

# ------------------------------------------------ queue + retry tests ---
test_queue_lists_pass_entries_in_order() {
  new_sandbox
  echo 1 > "$LOCAL/a.txt"
  mkdir -p "$LOCAL/b" "$LOCAL/hidden" "$LOCAL/c/keep" "$LOCAL/c/secret"
  echo x > "$LOCAL/c/keep/f.txt"
  write_config
  printf '%s\n' "$LOCAL/hidden" "$LOCAL/c/secret" > "$XDG_CONFIG_HOME/proton-sync/excludes.list"
  run_once
  local want got
  want="$(printf 'done\t%s\t\ndone\t%s\t\ndone\t%s\t\n' "$LOCAL/a.txt" "$LOCAL/b" "$LOCAL/c/keep")"
  got="$(queue)"
  if [[ "$got" == "$want" ]]; then
    pass "$FUNCNAME"
  else
    fail "$FUNCNAME" "queue.tsv differs (excluded entries must be absent, parents with excludes expanded):"$'\n'"$got"
  fi
  cleanup
}

test_queue_shows_uploading_and_pending_during_pass() {
  new_sandbox
  echo 1 > "$LOCAL/a.txt"; echo 2 > "$LOCAL/b.txt"; echo 3 > "$LOCAL/c.txt"
  write_config
  export FAKE_SLEEP=0.6
  "$DAEMON" --once >/dev/null 2>&1 &
  local pid=$! snap="" i
  for (( i = 0; i < 60; i++ )); do
    snap="$(queue)"
    grep -q '^uploading' <<<"$snap" && break
    sleep 0.1
  done
  wait "$pid"
  unset FAKE_SLEEP
  local n_up n_pending
  n_up="$(grep -c '^uploading' <<<"$snap")"
  n_pending="$(grep -c '^pending' <<<"$snap")"
  if [[ "$n_up" == "1" && "$n_pending" -ge 1 ]] \
     && [[ "$(queue | grep -c '^done')" == "3" ]]; then
    pass "$FUNCNAME"
  else
    fail "$FUNCNAME" "mid-pass snapshot: uploading=$n_up pending=$n_pending; final: $(queue | cut -f1 | tr '\n' ' ')"
  fi
  cleanup
}

test_failed_upload_is_recorded_and_pass_continues() {
  new_sandbox
  echo 1 > "$LOCAL/a.txt"; echo 2 > "$LOCAL/bad.txt"; echo 3 > "$LOCAL/c.txt"
  write_config
  export FAKE_FAIL_PATH="$LOCAL/bad.txt"
  run_once
  unset FAKE_FAIL_PATH
  local line
  line="$(queue | grep "$LOCAL/bad.txt")"
  if [[ "$line" != failed$'\t'"$LOCAL/bad.txt"$'\t'"Error: something went wrong" ]]; then
    fail "$FUNCNAME" "expected failed line with reason, got: $line"
  elif ! calls | grep -q "upload .* $LOCAL/c.txt " || [[ "$(queue | grep -c '^done')" != "2" ]]; then
    fail "$FUNCNAME" "entries after the failed one were not uploaded"
  elif [[ "$(status_of pass_errors)" != "1" || "$(status_of state)" != "idle" ]]; then
    fail "$FUNCNAME" "errors=$(status_of pass_errors) state=$(status_of state)"
  elif [[ "$(calls | grep -c "upload .* $LOCAL/bad.txt ")" != "1" ]]; then
    fail "$FUNCNAME" "a generic failure must not be retried"
  else
    pass "$FUNCNAME"
  fi
  cleanup
}

test_thumbnail_failure_retries_without_thumbnails() {
  new_sandbox
  mkdir -p "$LOCAL/scans"; echo x > "$LOCAL/scans/scan.tif"
  write_config
  export FAKE_THUMB_FAIL=1
  run_once
  unset FAKE_THUMB_FAIL
  local n
  n="$(calls | grep -c "filesystem upload")"
  if [[ "$n" != "2" ]]; then
    fail "$FUNCNAME" "expected 2 upload attempts, got $n"
  elif ! calls | grep -q -- "upload -d merge -f replace --skip-thumbnails $LOCAL/scans /my-files/Test"; then
    fail "$FUNCNAME" "retry did not pass --skip-thumbnails: $(calls | grep upload)"
  elif [[ "$(status_of pass_errors)" != "0" || "$(queue | cut -f1)" != "done" ]]; then
    fail "$FUNCNAME" "errors=$(status_of pass_errors) queue=$(queue | cut -f1)"
  elif [[ "$(status_of pass_items)" != "3" ]]; then
    # 1 item uploaded before the failure + 2 on the retry: all are real uploads
    fail "$FUNCNAME" "pass_items=$(status_of pass_items), expected 3"
  elif ! grep -q "retrying without thumbnails" "$STATE/sync.log"; then
    fail "$FUNCNAME" "no retry log line"
  else
    pass "$FUNCNAME"
  fi
  cleanup
}

test_vanished_file_retries_once_after_delay() {
  new_sandbox
  mkdir -p "$LOCAL/docs"; echo x > "$LOCAL/docs/f.txt"
  write_config
  export FAKE_ENOENT_ONCE=1 RETRY_DELAY=0
  run_once
  unset FAKE_ENOENT_ONCE RETRY_DELAY
  local n
  n="$(calls | grep -c "filesystem upload")"
  if [[ "$n" != "2" ]]; then
    fail "$FUNCNAME" "expected 2 upload attempts, got $n"
  elif [[ "$(status_of pass_errors)" != "0" || "$(queue | cut -f1)" != "done" ]]; then
    fail "$FUNCNAME" "errors=$(status_of pass_errors) queue=$(queue | cut -f1)"
  elif ! grep -q "changed or vanished during the upload, retrying" "$STATE/sync.log"; then
    fail "$FUNCNAME" "no retry log line"
  else
    pass "$FUNCNAME"
  fi
  cleanup
}

test_failed_upload_never_causes_trash() {
  # A failed upload must never be mistaken for a deletion, even with
  # deletion sync on and across several passes.
  new_sandbox
  echo 1 > "$LOCAL/a.txt"; echo 2 > "$LOCAL/bad.txt"
  write_config "SYNC_DELETES='true'"
  export FAKE_FAIL_PATH="$LOCAL/bad.txt"
  run_once; run_once
  unset FAKE_FAIL_PATH
  run_once
  if calls | grep -q "filesystem trash"; then
    fail "$FUNCNAME" "trash called: $(calls | grep trash)"
  elif [[ "$(queue | grep "$LOCAL/bad.txt" | cut -f1)" != "done" ]]; then
    fail "$FUNCNAME" "bad.txt not uploaded once the failure cleared"
  else
    pass "$FUNCNAME"
  fi
  cleanup
}

# -------------------------------------------------- incremental sync tests ---
# Files are created, then we wait past the second boundary before the pass
# so the pass stamp is strictly newer than their mtimes.
settle_mtimes() { sleep 1.1; }

test_second_pass_skips_unchanged_units() {
  new_sandbox
  mkdir -p "$LOCAL/docs"; echo 1 > "$LOCAL/docs/a.txt"; echo 2 > "$LOCAL/b.txt"
  write_config
  settle_mtimes; run_once
  : > "$FAKE_LOG"; : > "$STATE/events.tsv"
  run_once
  if calls | grep -q "filesystem upload"; then
    fail "$FUNCNAME" "uploads although nothing changed: $(calls | grep upload)"
  elif [[ "$(queue | cut -f1 | sort -u)" != "unchanged" ]]; then
    fail "$FUNCNAME" "queue states: $(queue | cut -f1 | tr '\n' ' ')"
  elif [[ "$(status_of state)" != "idle" || "$(status_of mode)" != "quick" ]]; then
    fail "$FUNCNAME" "state=$(status_of state) mode=$(status_of mode)"
  elif events | grep -qE '^(new|updated|uploading)'; then
    fail "$FUNCNAME" "events for unchanged units: $(events | grep -E '^(new|updated|uploading)')"
  else
    pass "$FUNCNAME"
  fi
  cleanup
}

test_changed_file_is_uploaded_alone() {
  new_sandbox
  mkdir -p "$LOCAL/docs/sub"; echo 1 > "$LOCAL/docs/a.txt"; echo 2 > "$LOCAL/docs/sub/b.txt"; echo 3 > "$LOCAL/docs/c.txt"
  write_config
  settle_mtimes; run_once
  settle_mtimes; : > "$FAKE_LOG"
  echo 22 > "$LOCAL/docs/sub/b.txt"
  run_once
  local ups; ups="$(calls | grep 'filesystem upload')"
  if [[ "$ups" != "filesystem upload -d merge -f replace $LOCAL/docs/sub/b.txt /my-files/Test/docs/sub" ]]; then
    fail "$FUNCNAME" "expected exactly the changed file to be uploaded into its remote folder, got:"$'\n'"$ups"
  elif [[ "$(queue | grep "$LOCAL/docs" | cut -f1)" != "done" ]]; then
    fail "$FUNCNAME" "docs not marked done: $(queue)"
  elif ! events | grep -q $'^updated\t'"$LOCAL/docs/sub/b.txt"; then
    fail "$FUNCNAME" "no updated event"
  else
    pass "$FUNCNAME"
  fi
  cleanup
}

test_new_subfolder_with_old_timestamps_is_uploaded_wholesale() {
  new_sandbox
  mkdir -p "$LOCAL/docs"; echo 1 > "$LOCAL/docs/a.txt"
  write_config
  settle_mtimes; run_once
  settle_mtimes; : > "$FAKE_LOG"
  # moved in from elsewhere: old mtimes on everything, only docs/ itself changes
  mkdir -p "$LOCAL/docs/moved/deep"; echo x > "$LOCAL/docs/moved/x.txt"; echo y > "$LOCAL/docs/moved/deep/y.txt"
  touch -d '2020-01-01' "$LOCAL/docs/moved/x.txt" "$LOCAL/docs/moved/deep/y.txt" "$LOCAL/docs/moved/deep" "$LOCAL/docs/moved"
  run_once
  local ups; ups="$(calls | grep 'filesystem upload')"
  if [[ "$ups" != "filesystem upload -d merge -f replace $LOCAL/docs/moved /my-files/Test/docs" ]]; then
    fail "$FUNCNAME" "expected the new folder uploaded as one unit, got:"$'\n'"$ups"
  else
    pass "$FUNCNAME"
  fi
  cleanup
}

test_many_changes_upload_the_whole_unit() {
  new_sandbox
  mkdir -p "$LOCAL/docs"; for i in $(seq 1 30); do echo $i > "$LOCAL/docs/f$i.txt"; done
  write_config
  settle_mtimes; run_once
  settle_mtimes; : > "$FAKE_LOG"
  for i in $(seq 1 25); do echo "v2 $i" > "$LOCAL/docs/f$i.txt"; done
  run_once
  local ups; ups="$(calls | grep 'filesystem upload')"
  if [[ "$ups" != "filesystem upload -d merge -f replace $LOCAL/docs /my-files/Test" ]]; then
    fail "$FUNCNAME" "expected one whole-unit upload, got $(calls | grep -c 'filesystem upload') calls"
  else
    pass "$FUNCNAME"
  fi
  cleanup
}

test_partial_upload_failure_falls_back_to_whole_unit() {
  new_sandbox
  mkdir -p "$LOCAL/docs"; echo 1 > "$LOCAL/docs/a.txt"; echo 2 > "$LOCAL/docs/b.txt"
  write_config
  settle_mtimes; run_once
  settle_mtimes; : > "$FAKE_LOG"
  echo 22 > "$LOCAL/docs/b.txt"
  export FAKE_FAIL_PATH="$LOCAL/docs/b.txt"
  run_once
  unset FAKE_FAIL_PATH
  if ! calls | grep -q "upload .* $LOCAL/docs/b.txt /my-files/Test/docs"; then
    fail "$FUNCNAME" "changed file was not tried first"
  elif ! calls | grep -q "upload -d merge -f replace $LOCAL/docs /my-files/Test"; then
    fail "$FUNCNAME" "no fallback to the whole unit: $(calls | grep upload)"
  elif [[ "$(queue | cut -f1)" != "done" || "$(status_of pass_errors)" != "0" ]]; then
    fail "$FUNCNAME" "queue=$(queue | cut -f1) errors=$(status_of pass_errors)"
  else
    pass "$FUNCNAME"
  fi
  cleanup
}

test_deletion_inside_unchanged_unit_is_still_trashed() {
  new_sandbox
  mkdir -p "$LOCAL/docs"; echo 1 > "$LOCAL/docs/a.txt"; echo 2 > "$LOCAL/docs/b.txt"
  write_config "SYNC_DELETES='true'"
  settle_mtimes; run_once
  settle_mtimes; : > "$FAKE_LOG"
  rm "$LOCAL/docs/b.txt"
  run_once
  if calls | grep -q "filesystem upload"; then
    fail "$FUNCNAME" "a deletion caused uploads: $(calls | grep upload)"
  elif ! calls | grep -q "filesystem trash /my-files/Test/docs/b.txt"; then
    fail "$FUNCNAME" "b.txt not trashed: $(calls | grep trash)"
  elif [[ "$(queue | cut -f1)" != "unchanged" ]]; then
    fail "$FUNCNAME" "queue=$(queue | cut -f1)"
  else
    pass "$FUNCNAME"
  fi
  cleanup
}

test_full_check_when_interval_elapsed_or_requested() {
  new_sandbox
  echo 1 > "$LOCAL/a.txt"; echo 2 > "$LOCAL/b.txt"
  write_config "FULL_CHECK_INTERVAL='0'"      # 0 = every pass is a full check
  settle_mtimes; run_once
  : > "$FAKE_LOG"
  run_once
  local n; n="$(calls | grep -c 'filesystem upload')"
  if [[ "$n" != "2" || "$(status_of mode)" != "full" ]]; then
    fail "$FUNCNAME" "interval 0: $n uploads, mode $(status_of mode)"; cleanup; return
  fi
  write_config "FULL_CHECK_INTERVAL='3600'"
  : > "$FAKE_LOG"; run_once
  if calls | grep -q "filesystem upload" || [[ "$(status_of mode)" != "quick" ]]; then
    fail "$FUNCNAME" "interval 3600 right after a full check should be quick/no uploads"; cleanup; return
  fi
  echo full > "$STATE/trigger/sync-now"           # the app's "Full check" button
  : > "$FAKE_LOG"; run_once
  n="$(calls | grep -c 'filesystem upload')"
  if [[ "$n" != "2" || "$(status_of mode)" != "full" ]]; then
    fail "$FUNCNAME" "trigger 'full': $n uploads, mode $(status_of mode)"; cleanup; return
  fi
  : > "$FAKE_LOG"; "$DAEMON" --once --full >/dev/null 2>&1
  n="$(calls | grep -c 'filesystem upload')"
  if [[ "$n" != "2" ]]; then
    fail "$FUNCNAME" "--once --full: $n uploads"
  else
    pass "$FUNCNAME"
  fi
  cleanup
}

test_interrupted_pass_resumes_where_it_stopped() {
  new_sandbox
  echo 1 > "$LOCAL/a.txt"; echo 2 > "$LOCAL/b.txt"; echo 3 > "$LOCAL/c.txt"
  write_config
  settle_mtimes
  export FAKE_SLEEP=1
  setsid "$DAEMON" --once >/dev/null 2>&1 &
  local pid=$! i
  for (( i = 0; i < 50; i++ )); do          # wait until a.txt is done, b.txt in flight
    [[ "$(queue | grep "$LOCAL/a.txt" | cut -f1)" == "done" ]] && break
    sleep 0.1
  done
  kill -TERM -- "-$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  unset FAKE_SLEEP
  local before; before="$(calls | grep -c 'filesystem upload')"
  : > "$FAKE_LOG"
  run_once
  if calls | grep -q "upload .* $LOCAL/a.txt "; then
    fail "$FUNCNAME" "a.txt (already synced before the interruption) was uploaded again"
  elif ! calls | grep -q "upload .* $LOCAL/b.txt " || ! calls | grep -q "upload .* $LOCAL/c.txt "; then
    fail "$FUNCNAME" "b/c not uploaded after resume (before: $before calls): $(calls | grep upload)"
  elif [[ "$(queue | grep "$LOCAL/a.txt" | cut -f1)" != "unchanged" ]]; then
    fail "$FUNCNAME" "a.txt state: $(queue | grep a.txt | cut -f1)"
  else
    pass "$FUNCNAME"
  fi
  cleanup
}

test_changed_folders_restart_incremental_bookkeeping() {
  new_sandbox
  echo 1 > "$LOCAL/a.txt"
  write_config
  settle_mtimes; run_once
  write_config "REMOTE_ROOT='/my-files/Other'"
  : > "$FAKE_LOG"; run_once
  if ! calls | grep -q "upload -d merge -f replace $LOCAL/a.txt /my-files/Other" || [[ "$(status_of mode)" != "full" ]]; then
    fail "$FUNCNAME" "new destination must get a full upload: $(calls | grep upload) mode=$(status_of mode)"
  else
    pass "$FUNCNAME"
  fi
  cleanup
}

# ------------------------------------------------------ live feed tests ---
test_events_report_new_updated_and_unchanged_files() {
  new_sandbox
  mkdir -p "$LOCAL/docs"
  echo 1 > "$LOCAL/docs/a.txt"; echo 2 > "$LOCAL/docs/b.txt"; echo 3 > "$LOCAL/top.txt"
  write_config
  run_once
  local ok=1
  events | grep -q $'^uploading\t'"$LOCAL/docs"$'\t2 new' || { ok=0; echo "  uploading event lacks '2 new': $(events | grep ^uploading)"; }
  events | grep -q $'^new\t'"$LOCAL/docs/a.txt" || { ok=0; echo "  first pass: a.txt not reported as new"; }
  events | grep -q $'^new\t'"$LOCAL/docs/b.txt" || { ok=0; echo "  first pass: b.txt not reported as new"; }
  events | grep -q $'^new\t'"$LOCAL/top.txt" || { ok=0; echo "  first pass: top.txt not reported as new"; }
  events | grep -q $'^done\t'"$LOCAL/docs"$'\t2 uploaded' || { ok=0; echo "  done event missing counts: $(events | grep ^done)"; }
  events | grep -q '^pass-start' && events | grep -q '^pass-end' || { ok=0; echo "  pass events missing"; }
  : > "$STATE/events.tsv"
  sleep 1.1                       # mtime resolution vs. the stamp
  echo 22 > "$LOCAL/docs/b.txt"   # updated
  echo 4 > "$LOCAL/docs/c.txt"    # new
  run_once
  events | grep -q $'^uploading\t'"$LOCAL/docs"$'\t1 new · 1 updated' || { ok=0; echo "  second pass uploading detail wrong: $(events | grep ^uploading)"; }
  events | grep -q $'^updated\t'"$LOCAL/docs/b.txt" || { ok=0; echo "  b.txt not reported as updated: $(events | grep -E '^(new|updated)')"; }
  events | grep -q $'^new\t'"$LOCAL/docs/c.txt" || { ok=0; echo "  c.txt not reported as new"; }
  events | grep -qE $'^(new|updated)\t'"$LOCAL/docs/a.txt" && { ok=0; echo "  unchanged a.txt reported"; }
  events | grep -qE $'^(new|updated)\t'"$LOCAL/top.txt" && { ok=0; echo "  unchanged top.txt reported"; }
  [[ $ok == 1 ]] && pass "$FUNCNAME" || fail "$FUNCNAME" "see lines above"
  cleanup
}

test_events_silent_when_cli_uploaded_nothing() {
  new_sandbox
  mkdir -p "$LOCAL/docs"; echo 1 > "$LOCAL/docs/a.txt"
  write_config
  run_once
  : > "$STATE/events.tsv"
  export FAKE_NOTHING_NEW=1
  run_once
  unset FAKE_NOTHING_NEW
  if events | grep -qE '^(new|updated)'; then
    fail "$FUNCNAME" "file events although the CLI uploaded 0 items: $(events | grep -E '^(new|updated)')"
  elif ! events | grep -q $'^done\t'"$LOCAL/docs"$'\tnothing new'; then
    fail "$FUNCNAME" "expected 'nothing new' done event: $(events | grep ^done)"
  else
    pass "$FUNCNAME"
  fi
  cleanup
}

test_events_for_trash_failure_and_retry() {
  new_sandbox
  echo a > "$LOCAL/a.txt"; echo b > "$LOCAL/b.txt"; echo c > "$LOCAL/bad.txt"
  mkdir -p "$LOCAL/scans"; echo s > "$LOCAL/scans/x.tif"
  write_config "SYNC_DELETES='true'"
  run_once
  rm "$LOCAL/b.txt"
  : > "$STATE/events.tsv"
  export FAKE_FAIL_PATH="$LOCAL/bad.txt" FAKE_THUMB_FAIL=1
  run_once
  unset FAKE_FAIL_PATH FAKE_THUMB_FAIL
  local ok=1
  events | grep -q $'^trashed\t'"$LOCAL/b.txt" || { ok=0; echo "  no trashed event: $(events | grep trash)"; }
  events | grep -q $'^failed\t'"$LOCAL/bad.txt"$'\tError: something went wrong' || { ok=0; echo "  no failed event with reason"; }
  events | grep -q $'^retry\t'"$LOCAL/scans" || { ok=0; echo "  no retry event"; }
  [[ $ok == 1 ]] && pass "$FUNCNAME" || fail "$FUNCNAME" "see lines above"
  cleanup
}

test_status_shows_file_being_read_during_folder_upload() {
  new_sandbox
  mkdir -p "$LOCAL/big"; echo 1 > "$LOCAL/big/movie.mp4"
  write_config
  export FAKE_HOLD_OPEN="$LOCAL/big/movie.mp4" FAKE_SLEEP=2 SAMPLE_INTERVAL=0.2
  "$DAEMON" --once >/dev/null 2>&1 &
  local pid=$! seen="" i
  for (( i = 0; i < 60; i++ )); do
    seen="$(python3 -c "import json; print(json.load(open('$STATE/status.json')).get('file',''))" 2>/dev/null)"
    [[ -n "$seen" ]] && break
    sleep 0.1
  done
  wait "$pid"
  unset FAKE_HOLD_OPEN FAKE_SLEEP SAMPLE_INTERVAL
  if [[ "$seen" == "$LOCAL/big/movie.mp4" ]]; then
    pass "$FUNCNAME"
  else
    fail "$FUNCNAME" "status.json never showed the open file (got '$seen')"
  fi
  cleanup
}

test_events_file_is_trimmed() {
  new_sandbox
  echo a > "$LOCAL/a.txt"
  write_config
  mkdir -p "$STATE"
  for (( i = 0; i < 3500; i++ )); do printf '1\tnew\t/x/%s\t\n' "$i"; done > "$STATE/events.tsv"
  run_once
  local n; n="$(wc -l < "$STATE/events.tsv")"
  if (( n <= 3000 )) && events | grep -q '^pass-end'; then
    pass "$FUNCNAME"
  else
    fail "$FUNCNAME" "events.tsv has $n lines after a pass"
  fi
  cleanup
}

# ------------------------------------------------ data-safety guards ---
test_unplugged_drive_does_not_trash_everything() {
  # The mount point of an unplugged drive is an empty folder on another
  # filesystem. That must never be read as "the user deleted everything".
  new_sandbox
  echo a > "$LOCAL/a.txt"; echo b > "$LOCAL/b.txt"
  write_config "SYNC_DELETES='true'"
  export FS_ID_OVERRIDE=100
  run_once
  rm "$LOCAL/a.txt" "$LOCAL/b.txt"
  export FS_ID_OVERRIDE=200           # drive gone: empty mount point, other fs
  run_once
  if calls | grep -q "filesystem trash"; then
    fail "$FUNCNAME" "unplugged drive caused trashing: $(calls | grep trash)"; unset FS_ID_OVERRIDE; cleanup; return
  fi
  if ! grep -q "drive unplugged?" "$STATE/sync.log"; then
    fail "$FUNCNAME" "precaution not logged"; unset FS_ID_OVERRIDE; cleanup; return
  fi
  export FS_ID_OVERRIDE=100           # drive back, b.txt was deleted meanwhile
  echo a > "$LOCAL/a.txt"
  run_once
  unset FS_ID_OVERRIDE
  if calls | grep -q "filesystem trash /my-files/Test/b.txt" \
     && [[ "$(calls | grep -c 'filesystem trash')" == "1" ]]; then
    pass "$FUNCNAME"
  else
    fail "$FUNCNAME" "expected only b.txt trashed after the drive returned, got: $(calls | grep trash)"
  fi
  cleanup
}

test_emptied_folder_on_same_disk_is_a_real_deletion() {
  new_sandbox
  echo a > "$LOCAL/a.txt"; echo b > "$LOCAL/b.txt"
  write_config "SYNC_DELETES='true'"
  run_once
  rm "$LOCAL/a.txt" "$LOCAL/b.txt"
  run_once
  if [[ "$(calls | grep -c 'filesystem trash')" == "2" ]]; then
    pass "$FUNCNAME"
  else
    fail "$FUNCNAME" "expected both files trashed, got: $(calls | grep trash)"
  fi
  cleanup
}

test_changed_folders_reset_deletion_tracking() {
  new_sandbox
  echo a > "$LOCAL/a.txt"; echo b > "$LOCAL/b.txt"
  write_config "SYNC_DELETES='true'"
  run_once
  # user picks another destination and deletes b in between
  write_config "SYNC_DELETES='true'" "REMOTE_ROOT='/my-files/Other'"
  rm "$LOCAL/b.txt"
  run_once
  if calls | grep -q "filesystem trash"; then
    fail "$FUNCNAME" "old manifest applied to the new destination: $(calls | grep trash)"; cleanup; return
  fi
  if ! grep -q "deletion tracking starts fresh" "$STATE/sync.log"; then
    fail "$FUNCNAME" "reset not logged"; cleanup; return
  fi
  rm "$LOCAL/a.txt"
  run_once
  if calls | grep -q "filesystem trash /my-files/Other/a.txt" \
     && [[ "$(calls | grep -c 'filesystem trash')" == "1" ]]; then
    pass "$FUNCNAME"
  else
    fail "$FUNCNAME" "deletion after the reset not propagated correctly: $(calls | grep trash)"
  fi
  cleanup
}

test_missing_folder_at_start_exits_with_error_state() {
  new_sandbox
  write_config "LOCAL_ROOT='$SB/not-there'" "SYNC_DELETES='true'"
  run_once
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    fail "$FUNCNAME" "exit code $rc, expected 0"
  elif [[ "$(status_of state)" != "error" ]] || [[ "$(status_of current)" != "Sync folder not found: $SB/not-there" ]]; then
    fail "$FUNCNAME" "state=$(status_of state) current=$(status_of current)"
  elif calls | grep -qE "filesystem (upload|trash)"; then
    fail "$FUNCNAME" "CLI touched although the folder is missing"
  else
    pass "$FUNCNAME"
  fi
  cleanup
}

test_unplugged_folder_in_watch_mode_trashes_nothing_and_resumes() {
  new_sandbox
  echo a > "$LOCAL/a.txt"; echo b > "$LOCAL/b.txt"
  write_config "POLL_INTERVAL='3600'" "DEBOUNCE='0'" "SYNC_DELETES='true'"
  use_polling
  export TRIGGER_TICK=1
  start_watch
  if ! wait_for_passes 1 10; then
    fail "$FUNCNAME" "first pass did not finish"; stop_watch; cleanup; return
  fi
  sleep 1.2
  mv "$LOCAL" "$LOCAL.away"          # drive unplugged
  touch "$STATE/trigger/sync-now"
  local i
  for (( i = 0; i < 40; i++ )); do
    grep -q "sync folder not found" "$STATE/sync.log" 2>/dev/null && break
    sleep 0.2
  done
  local state; state="$(status_of state)"
  mv "$LOCAL.away" "$LOCAL"          # drive back
  if ! wait_for_passes 2 10; then
    fail "$FUNCNAME" "did not resume after the folder came back: $(tail -3 "$STATE/sync.log")"
  elif calls | grep -q "filesystem trash"; then
    fail "$FUNCNAME" "trashed while the folder was away: $(calls | grep trash)"
  elif [[ "$state" != "error" ]]; then
    fail "$FUNCNAME" "state while away was $state, expected error"
  elif ! grep -q "sync folder is back" "$STATE/sync.log"; then
    fail "$FUNCNAME" "resume not logged"
  else
    pass "$FUNCNAME"
  fi
  stop_watch
  unset TRIGGER_TICK
  cleanup
}

test_settings_apply_to_running_daemon_on_next_pass() {
  new_sandbox
  echo a > "$LOCAL/a.txt"
  write_config "POLL_INTERVAL='3600'" "DEBOUNCE='0'"
  use_polling
  export TRIGGER_TICK=1
  start_watch
  if ! wait_for_passes 1 10; then
    fail "$FUNCNAME" "first pass did not finish"; stop_watch; cleanup; return
  fi
  sleep 1.2
  # the settings app saves a new destination + an exclude, then asks for a pass
  mkdir -p "$LOCAL/private"; echo p > "$LOCAL/private/p.txt"
  write_config "POLL_INTERVAL='3600'" "DEBOUNCE='0'" "REMOTE_ROOT='/my-files/New'"
  echo "$LOCAL/private" > "$XDG_CONFIG_HOME/proton-sync/excludes.list"
  touch "$STATE/trigger/sync-now"
  if ! wait_for_passes 2 8; then
    fail "$FUNCNAME" "no pass after trigger"
  elif ! calls | grep -q "upload -d merge -f replace $LOCAL/a.txt /my-files/New"; then
    fail "$FUNCNAME" "new destination not used: $(calls | grep upload | tail -2)"
  elif calls | grep -q "upload .*$LOCAL/private"; then
    fail "$FUNCNAME" "new exclude not applied"
  else
    pass "$FUNCNAME"
  fi
  stop_watch
  unset TRIGGER_TICK
  cleanup
}

# ------------------------------------------------------ watch-mode tests ---
test_manual_trigger_starts_pass_in_poll_mode() {
  new_sandbox
  echo 1 > "$LOCAL/a.txt"
  write_config "POLL_INTERVAL='3600'" "DEBOUNCE='0'"
  use_polling
  export TRIGGER_TICK=1
  start_watch
  if ! wait_for_passes 1 10; then
    fail "$FUNCNAME" "first pass did not finish: $(cat "$SB/watch.out")"; stop_watch; cleanup; return
  fi
  sleep 1.2   # let the daemon settle into the poll loop
  local state; state="$(status_of state)"
  touch "$STATE/trigger/sync-now"
  if ! wait_for_passes 2 8; then
    fail "$FUNCNAME" "no pass after trigger (state before: $state): $(tail -3 "$STATE/sync.log")"
  elif [[ "$state" != "polling" ]]; then
    fail "$FUNCNAME" "expected polling state before trigger, got $state"
  elif ! grep -q "sync requested manually" "$STATE/sync.log"; then
    fail "$FUNCNAME" "trigger not logged as manual request"
  elif [[ -e "$STATE/trigger/sync-now" ]]; then
    fail "$FUNCNAME" "trigger file not consumed"
  else
    pass "$FUNCNAME"
  fi
  stop_watch
  unset TRIGGER_TICK
  cleanup
}

test_manual_trigger_in_inotify_mode_skips_debounce() {
  new_sandbox
  echo 1 > "$LOCAL/a.txt"
  write_config "POLL_INTERVAL='3600'" "DEBOUNCE='30'"
  use_fake_inotify
  start_watch
  if ! wait_for_passes 1 10; then
    fail "$FUNCNAME" "first pass did not finish: $(cat "$SB/watch.out")"; stop_watch; cleanup; return
  fi
  sleep 1
  touch "$STATE/trigger/sync-now"
  if ! wait_for_passes 2 8; then
    fail "$FUNCNAME" "no prompt pass after trigger (debounce must be skipped): $(tail -3 "$STATE/sync.log")"
  elif ! grep -q -- "--format %w%f" "$FAKE_INOTIFY_LOG" || ! grep -q "$STATE/trigger" "$FAKE_INOTIFY_LOG"; then
    fail "$FUNCNAME" "inotifywait not asked to watch the trigger dir: $(cat "$FAKE_INOTIFY_LOG")"
  elif ! grep -q "sync requested manually" "$STATE/sync.log"; then
    fail "$FUNCNAME" "trigger not logged as manual request"
  else
    pass "$FUNCNAME"
  fi
  stop_watch
  cleanup
}

test_inotify_change_event_leads_to_pass() {
  new_sandbox
  echo 1 > "$LOCAL/a.txt"
  write_config "POLL_INTERVAL='3600'" "DEBOUNCE='0'"
  use_fake_inotify
  start_watch
  if ! wait_for_passes 1 10; then
    fail "$FUNCNAME" "first pass did not finish"; stop_watch; cleanup; return
  fi
  sleep 1
  echo 2 > "$LOCAL/b.txt"
  touch "$FAKE_INOTIFY_EVENT"
  if ! wait_for_passes 2 8; then
    fail "$FUNCNAME" "no pass after inotify event: $(tail -3 "$STATE/sync.log")"
  elif ! grep -q "change detected (inotify)" "$STATE/sync.log"; then
    fail "$FUNCNAME" "event not logged"
  elif ! calls | grep -q "upload .* $LOCAL/b.txt "; then
    fail "$FUNCNAME" "new file not uploaded in the follow-up pass"
  else
    pass "$FUNCNAME"
  fi
  stop_watch
  cleanup
}

test_edits_during_pass_are_synced_in_followup_pass() {
  # Files changed while a pass runs are invisible to inotify (it is not
  # listening then) — the daemon must notice them itself afterwards.
  new_sandbox
  echo 1 > "$LOCAL/a.txt"
  write_config "POLL_INTERVAL='3600'" "DEBOUNCE='0'"
  use_fake_inotify
  export FAKE_TOUCH="$LOCAL/late.txt"
  start_watch
  if ! wait_for_passes 2 10; then
    fail "$FUNCNAME" "no follow-up pass for the file created mid-pass: $(tail -3 "$STATE/sync.log")"
  elif ! calls | grep -q "upload .* $LOCAL/late.txt "; then
    fail "$FUNCNAME" "late.txt was never uploaded"
  elif ! grep -q "changes made during the last pass" "$STATE/sync.log"; then
    fail "$FUNCNAME" "follow-up not logged"
  else
    sleep 1.5
    if [[ "$(passes_done)" != "2" ]]; then
      fail "$FUNCNAME" "daemon kept syncing without changes ($(passes_done) passes)"
    else
      pass "$FUNCNAME"
    fi
  fi
  stop_watch
  unset FAKE_TOUCH
  cleanup
}

test_stop_signal_writes_stopped_state() {
  new_sandbox
  echo 1 > "$LOCAL/a.txt"
  write_config "POLL_INTERVAL='3600'" "DEBOUNCE='0'"
  use_polling
  export TRIGGER_TICK=1
  start_watch
  wait_for_passes 1 10
  stop_watch
  unset TRIGGER_TICK
  if [[ "$(status_of state)" == "stopped" && ! -e "$STATE/daemon.pid" ]]; then
    pass "$FUNCNAME"
  else
    fail "$FUNCNAME" "state=$(status_of state) pidfile=$([[ -e "$STATE/daemon.pid" ]] && echo present || echo gone)"
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

test_failure_reason_picks_useful_line() {
  new_sandbox
  write_config
  # shellcheck disable=SC1090
  source "$DAEMON"
  set +o pipefail
  local ok=1 r
  r="$(failure_reason $'Transfer summary:\n  Uploaded: 3 items (1 B)\n  - ok.jpg\n  Failed: 1 items\n  - scan.tif: ValidationError: Failed to generate thumbnails\n1 item(s) failed to upload')"
  [[ "$r" == "scan.tif: ValidationError: Failed to generate thumbnails" ]] || { ok=0; echo "  failed-list: got '$r'"; }
  r="$(failure_reason $'Transfer summary:\n  Uploaded: 0 items (0 B)\n=====\nENOENT: no such file or directory, statx \'/x/y\'\n    path: "/x/y"\n      at foo (src/a.ts:1:1)')"
  [[ "$r" == "ENOENT: no such file or directory, statx '/x/y'" ]] || { ok=0; echo "  enoent: got '$r'"; }
  r="$(failure_reason $'something\n\nlast\twords\n')"
  [[ "$r" == "last words" ]] || { ok=0; echo "  fallback: got '$r'"; }
  r="$(failure_reason "")"
  [[ "$r" == "" ]] || { ok=0; echo "  empty: got '$r'"; }
  [[ $ok == 1 ]] && pass "$FUNCNAME" || fail "$FUNCNAME" "see lines above"
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
  test_remote_copy_already_gone_is_not_an_error
  test_second_instance_refuses
  test_queue_lists_pass_entries_in_order
  test_queue_shows_uploading_and_pending_during_pass
  test_failed_upload_is_recorded_and_pass_continues
  test_thumbnail_failure_retries_without_thumbnails
  test_vanished_file_retries_once_after_delay
  test_failed_upload_never_causes_trash
  test_second_pass_skips_unchanged_units
  test_changed_file_is_uploaded_alone
  test_new_subfolder_with_old_timestamps_is_uploaded_wholesale
  test_many_changes_upload_the_whole_unit
  test_partial_upload_failure_falls_back_to_whole_unit
  test_deletion_inside_unchanged_unit_is_still_trashed
  test_full_check_when_interval_elapsed_or_requested
  test_interrupted_pass_resumes_where_it_stopped
  test_changed_folders_restart_incremental_bookkeeping
  test_events_report_new_updated_and_unchanged_files
  test_events_silent_when_cli_uploaded_nothing
  test_events_for_trash_failure_and_retry
  test_status_shows_file_being_read_during_folder_upload
  test_events_file_is_trimmed
  test_unplugged_drive_does_not_trash_everything
  test_emptied_folder_on_same_disk_is_a_real_deletion
  test_changed_folders_reset_deletion_tracking
  test_missing_folder_at_start_exits_with_error_state
  test_unplugged_folder_in_watch_mode_trashes_nothing_and_resumes
  test_settings_apply_to_running_daemon_on_next_pass
  test_manual_trigger_starts_pass_in_poll_mode
  test_manual_trigger_in_inotify_mode_skips_debounce
  test_inotify_change_event_leads_to_pass
  test_edits_during_pass_are_synced_in_followup_pass
  test_stop_signal_writes_stopped_state
  test_secret_scanner_blocks_planted_secrets
  test_secret_scanner_blocks_forbidden_filenames
  test_secret_scanner_passes_clean_files
  test_secret_scanner_all_mode_scans_repo
  test_parse_uploaded_units
  test_json_escape
  test_failure_reason_picks_useful_line
  test_build_manifest_prunes_excludes
)

if [[ $# -eq 1 ]]; then
  "$1"
else
  for t in "${BASH_TESTS[@]}"; do "$t"; done
fi

echo
PY_OK=1
python3 "$ROOT/tests/test-settings.py" || PY_OK=0
python3 "$ROOT/tests/test-reconcile.py" || PY_OK=0

echo
echo "bash: $PASSED passed, $FAILED failed; python: $([[ $PY_OK == 1 ]] && echo ok || echo FAILED)"
[[ $FAILED -eq 0 && $PY_OK -eq 1 ]] || exit 1
