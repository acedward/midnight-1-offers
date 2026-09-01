#!/usr/bin/env bash
# Fail if this PUBLIC repository carries any byte of the PRIVATE relay/intents-UI source.
#
#   ./scripts/verify-no-private-source.sh              # scan the tracked tree
#   ./scripts/verify-no-private-source.sh --self-test  # also prove every rule bites
#
# The rules, the allowlist and why each exists live in scripts/lib/leak_scan.py. In short:
# the repository may NAME `shieldedtech/midnight-intents-swaps` (README prose, `#` comments,
# the pinned identity in config/artifact-decisions.json) and may never CARRY its content —
# no vendored files, no patches quoting it, no copied lockfiles, no build outputs. Relay and
# intents-UI builds read an operator-local clone through RELAY_SOURCE_DIR instead.
#
# DELIBERATELY DEPENDENCY-FREE: it does not source scripts/lib/common.sh, need Docker, a
# network, or a populated .env. A leak gate has to run in the most degraded checkout there
# is — including a pre-commit hook on a tree where nothing else works yet.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCANNER="$REPO_ROOT/scripts/lib/leak_scan.py"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
else
  C_RESET=""; C_RED=""; C_GREEN=""
fi

command -v python3 >/dev/null 2>&1 || {
  printf '    %sFAIL%s python3 is required to run the private-source leak scan\n' "$C_RED" "$C_RESET" >&2
  exit 1
}
[[ -f "$SCANNER" ]] || {
  printf '    %sFAIL%s missing leak scanner: %s\n' "$C_RED" "$C_RESET" "$SCANNER" >&2
  exit 1
}
git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || {
  printf '    %sFAIL%s not a git checkout, so the tracked file list cannot be read: %s\n' \
    "$C_RED" "$C_RESET" "$REPO_ROOT" >&2
  exit 1
}

if python3 "$SCANNER" "$REPO_ROOT" "$@"; then
  printf '    %sOK%s   no private (shieldedtech/midnight-intents-swaps) source is committed\n' \
    "$C_GREEN" "$C_RESET"
  exit 0
fi

printf '    %sFAIL%s PRIVATE SOURCE DETECTED IN A PUBLIC REPOSITORY — do not push\n' \
  "$C_RED" "$C_RESET" >&2
exit 1
