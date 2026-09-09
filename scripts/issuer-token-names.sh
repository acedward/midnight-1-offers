#!/usr/bin/env bash
# issuer-token-names.sh — print this stack's six tokens as the
# `NAME=<64-hex colour>:<decimals>:<label>` list the intents UI is built with, ready to paste
# into `.env`.
#
#   ./scripts/issuer-token-names.sh                 # INTENTS_UI_TOKEN_NAMES=TWBTC=…:8:twBTC,…
#   ./scripts/issuer-token-names.sh --value-only    # just the value, for $( ) substitution
#   ./scripts/issuer-token-names.sh --table         # NAME, decimals, privacy, colour
#
# ── WHY THIS EXISTS (00020 PR C) ─────────────────────────────────────────────
# `INTENTS_UI_TOKEN_NAMES` is a BUILD arg, and that is upstream's design rather than this
# repository's choice: the intents UI resolves a colour's label and its decimals from the
# config block baked into `index.html` at build time. The relay's `/tokens` carries raw
# colours and nothing else.
#
# ── WHY EACH ENTRY CARRIES THREE FIELDS SINCE 00020 PR F ────────────────────
# At `RELAY_REF=b32e0b100` the UI reads `TOKEN_<NAME>` plus an optional
# `METADATA_TOKEN_<NAME>_LABEL` and an optional `METADATA_TOKEN_<NAME>_DECIMALS`, and it
# scales the amounts it renders by those decimals. The defaults are the whole point: with no
# label it shows the raw key, which is cosmetic — but with no decimals it assumes **SIX**,
# which is wrong for TWBTC (8) and wrong by twelve orders of magnitude for TWETH (18), and it
# is wrong SILENTLY. Both values are in the registry this script already reads, so it emits
# them: the label is the registry's own `symbol` (`twBTC`), the decimals its `decimals`.
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
      sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

# One awk pass, and a strict one: a row whose id is not 64 lowercase hex, whose decimals are
# not 1-2 digits, or whose symbol carries a character the UI knob refuses is DROPPED and
# reported by name, so a malformed registry cannot quietly produce a shorter list or a
# mis-scaled token. The intents-ui Dockerfile refuses all three anyway — this reports them
# here instead, where the operator can see which token it was.
PAIRS="$(printf '%s\n' "$REPORT" | awk '
  $1 == "ISSUER_TOKEN" {
    name = $2; id = ""; dec = ""; priv = ""; sym = ""
    for (i = 3; i <= NF; i++) {
      if ($i ~ /^id=/)       { id = substr($i, 4) }
      if ($i ~ /^decimals=/) { dec = substr($i, 10) }
      if ($i ~ /^privacy=/)  { priv = substr($i, 9) }
      if ($i ~ /^symbol=/)   { sym = substr($i, 8) }
    }
    if (id !~ /^[0-9a-f]{64}$/) { printf "BAD %s bad-colour %s\n", name, id > "/dev/stderr"; next }
    if (dec !~ /^[0-9][0-9]?$/) { printf "BAD %s bad-decimals %s\n", name, dec > "/dev/stderr"; next }
    if (sym !~ /^[A-Za-z0-9._-]{1,15}$/) { printf "BAD %s bad-symbol %s\n", name, sym > "/dev/stderr"; next }
    printf "%s\t%s\t%s\t%s\t%s\n", name, id, dec, priv, sym
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
    # `<NAME>=<colour>:<decimals>:<label>` — the three-field entry images/intents-ui/Dockerfile
    # parses. The label is the registry's own symbol, so the UI reads `twBTC` rather than the
    # key `TOKEN_TWBTC`, and the decimals are the registry's, so an 8- or 18-decimal token is
    # not rendered as if it had six.
    VALUE="$(printf '%s\n' "$PAIRS" | awk -F'\t' '{ printf "%s%s=%s:%s:%s", sep, $1, $2, $3, $5; sep="," }')"
    if [[ "$MODE" == "value" ]]; then
      printf '%s\n' "$VALUE"
    else
      printf 'INTENTS_UI_TOKEN_NAMES=%s\n' "$VALUE"
    fi
    ;;
esac
