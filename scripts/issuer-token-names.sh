#!/usr/bin/env bash
# issuer-token-names.sh — print this stack's six tokens as the `NAME=<64-hex colour>` list the
# intents UI is built with, ready to paste into `.env`.
#
#   ./scripts/issuer-token-names.sh                 # INTENTS_UI_TOKEN_NAMES=TWBTC=…,TWETH=…
#   ./scripts/issuer-token-names.sh --value-only    # just the value, for $( ) substitution
#   ./scripts/issuer-token-names.sh --table         # NAME, decimals, privacy, colour
#
# ── WHY THIS EXISTS (00020 PR C) ─────────────────────────────────────────────
# `INTENTS_UI_TOKEN_NAMES` is a BUILD arg, and that is upstream's design rather than this
# repository's choice: the intents UI's `tokenNames` module labels a colour by the
# `TOKEN_<NAME>` key it finds in the config block baked into `index.html` at build time, and
# falls back to the colour's last 8 hex characters when there is none. The relay's `/tokens`
# carries raw colours and nothing else.
#
# The colours, meanwhile, exist only AFTER `issuer-deploy` has run: each token's colour derives
# from the contract address it was deployed at, so they are new on every fresh chain. A build
# argument and a per-chain value cannot be reconciled in one pass, so this stack does not
# pretend otherwise — it makes the second pass ONE COMMAND instead of a manual transcription of
# six 64-character hex strings:
#
#   ./scripts/issuer-token-names.sh >> .env        # then, to rebuild just that image:
#   ./up.sh --with offerfiles --with solver --build
#
# Until then the UI shows hex tails, which is cosmetic and is stated in docs/KNOWN-LIMITATIONS.md.
#
# ── IT PARSES `issuer-registry`, NOT THE REGISTRY FILE ──────────────────────
# `images/issuer/m1/registry.ts` is the ONE reader of `metadata.undeployed.json` in this
# repository: it validates the file against the pinned tree's own JSON schema AND against the
# semantic validator the faucet site runs, then prints one `ISSUER_TOKEN` line per token on
# STDOUT. A second parser here would be a second definition of "what this stack's tokens are".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$REPO_ROOT/scripts/lib/common.sh"

MODE="env"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --value-only) MODE="value"; shift ;;
    --table)      MODE="table"; shift ;;
    -h|--help)
      sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) err "unknown option: $1"; exit 2 ;;
  esac
done

load_env
# Every fragment, so `docker compose run` does not report every other profile's containers as
# orphans (the same reason every other script here does it).
use_all_profiles

# `2>/dev/null` on the compose call, not on the capture: the reporter logs progress on stderr
# and prints its result on stdout, and mixing the two would put log lines through the parser.
# `|| true` so an absent registry yields an EMPTY string here and a named error below, rather
# than a `pipefail` exit from inside `$( )` (00011 C.8).
REPORT="$(dc run --rm --no-deps -T issuer-registry 2>/dev/null || true)"

if [[ -z "${REPORT//[[:space:]]/}" ]]; then
  err "the issuer registry reporter produced nothing"
  info "is the \`issuer\` profile up? ./up.sh --with offerfiles --with issuer"
  exit 1
fi

# One awk pass, and a strict one: a line whose id is not 64 lowercase hex is DROPPED and
# counted, so a malformed registry cannot quietly produce a shorter list. The intents-ui
# Dockerfile would reject such a value anyway — this reports it here instead, where the
# operator can see which token it was.
PAIRS="$(printf '%s\n' "$REPORT" | awk '
  $1 == "ISSUER_TOKEN" {
    name = $2; id = ""; dec = ""; priv = ""
    for (i = 3; i <= NF; i++) {
      if ($i ~ /^id=/)       { id = substr($i, 4) }
      if ($i ~ /^decimals=/) { dec = substr($i, 10) }
      if ($i ~ /^privacy=/)  { priv = substr($i, 9) }
    }
    if (id !~ /^[0-9a-f]{64}$/) { printf "BAD %s %s\n", name, id > "/dev/stderr"; next }
    printf "%s\t%s\t%s\t%s\n", name, id, dec, priv
  }
')"

COUNT="$(printf '%s\n' "$PAIRS" | grep -c . || true)"
if [[ "${COUNT:-0}" -eq 0 ]]; then
  err "no usable ISSUER_TOKEN lines in the registry report"
  exit 1
fi

case "$MODE" in
  table)
    printf '%-8s %-9s %-11s %s\n' NAME DECIMALS PRIVACY COLOUR
    printf '%s\n' "$PAIRS" | awk -F'\t' '{ printf "%-8s %-9s %-11s %s\n", $1, $3, $4, $2 }'
    ;;
  *)
    VALUE="$(printf '%s\n' "$PAIRS" | awk -F'\t' '{ printf "%s%s=%s", sep, $1, $2; sep="," }')"
    if [[ "$MODE" == "value" ]]; then
      printf '%s\n' "$VALUE"
    else
      printf 'INTENTS_UI_TOKEN_NAMES=%s\n' "$VALUE"
    fi
    ;;
esac
