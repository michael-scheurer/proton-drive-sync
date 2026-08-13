#!/usr/bin/env bash
#
# Refuses secrets and personal data in the repository.
#
#   tests/check-no-secrets.sh          scan files staged for commit
#                                      (this is what the pre-commit hook runs)
#   tests/check-no-secrets.sh --all    scan every tracked + untracked file
#
# Exits non-zero if anything suspicious is found. If you hit a false
# positive, fix the file or adjust the patterns here — never bypass with
# `git commit --no-verify` for a real finding.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."

MODE="${1:-staged}"
if [[ "$MODE" == "--all" ]]; then
  mapfile -t FILES < <(git ls-files --cached --others --exclude-standard)
  content() { cat -- "$1" 2>/dev/null; }
else
  mapfile -t FILES < <(git diff --cached --name-only --diff-filter=ACMR)
  content() { git show ":$1" 2>/dev/null; }
fi

FAIL=0
err() { echo "SECRET-CHECK: $1" >&2; FAIL=1; }

# File names that must never be committed, regardless of content.
NAME_DENY='(^|/)(\.env(\..+)?|[^/]*\.(pem|p12|pfx|key|keystore)|id_rsa[^/]*|id_ed25519[^/]*|[^/]*credentials[^/]*)$'

for f in "${FILES[@]}"; do
  [[ -z "$f" ]] && continue
  # The scanner itself contains the detection patterns.
  [[ "$f" == "tests/check-no-secrets.sh" ]] && continue

  if [[ "$f" =~ $NAME_DENY ]]; then
    err "forbidden file name: $f"
    continue
  fi
  if [[ "$(basename "$f")" == "proton-drive" ]]; then
    err "the proton-drive binary must never be committed (100 MB+ and not our license): $f"
    continue
  fi

  size="$(content "$f" | wc -c)"
  if (( size > 10 * 1024 * 1024 )); then
    err "file larger than 10 MB: $f"
    continue
  fi
  if content "$f" | LC_ALL=C grep -qP '\x00'; then
    err "binary file (this repo is text-only): $f"
    continue
  fi

  body="$(content "$f")"

  hits=""
  hits+="$(grep -nE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' <<<"$body" | sed 's/^/  private key @ line /')"$'\n'
  hits+="$(grep -niE -- '(password|passwd)[[:space:]]*[:=][[:space:]]*[^[:space:]$]' <<<"$body" | sed 's/^/  password assignment @ line /')"$'\n'
  hits+="$(grep -niE -- '(api[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret)[[:space:]]*[:=][[:space:]]*[^[:space:]$]' <<<"$body" | sed 's/^/  credential assignment @ line /')"$'\n'
  hits+="$(grep -nE -- 'AKIA[0-9A-Z]{16}' <<<"$body" | sed 's/^/  AWS key id @ line /')"$'\n'
  hits+="$(grep -nE -- '(ghp|gho|ghu|ghs|github_pat)_[A-Za-z0-9_]{20,}' <<<"$body" | sed 's/^/  GitHub token @ line /')"$'\n'
  hits+="$(grep -nE -- 'xox[baprs]-[A-Za-z0-9-]{10,}' <<<"$body" | sed 's/^/  Slack token @ line /')"$'\n'
  hits+="$(grep -nE -- 'eyJ[A-Za-z0-9_-]{20,}\.eyJ' <<<"$body" | sed 's/^/  JWT @ line /')"$'\n'
  # email addresses, except well-known non-personal ones
  hits+="$(grep -noE -- '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' <<<"$body" \
           | grep -viE '@(github\.com|example\.(com|org)|users\.noreply)' \
           | sed 's/^/  email address @ line /')"$'\n'
  # absolute home paths leak the local username
  hits+="$(grep -noE -- '/home/[A-Za-z0-9._-]+' <<<"$body" \
           | grep -vE '/home/(user|USERNAME)$' \
           | sed 's/^/  personal home path @ line /')"$'\n'

  hits="$(grep -v '^$' <<<"$hits" || true)"
  if [[ -n "$hits" ]]; then
    err "suspicious content in $f:"$'\n'"$hits"
  fi
done

if [[ $FAIL -ne 0 ]]; then
  echo >&2
  echo "Commit blocked. Remove the flagged content (or fix the pattern if it is a real false positive)." >&2
  exit 1
fi
echo "secret check: clean ($MODE, ${#FILES[@]} files)"
