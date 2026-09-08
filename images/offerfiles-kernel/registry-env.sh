#!/usr/bin/env bash
# registry-env.sh — THE TOKEN HANDOFF, kernel-image side. SOURCED, never executed.
#
# Since kernel #69 this stack's tokens are not derived from a contract address any more: they
# are ISSUED, once per chain, by the `issuer` profile (images/issuer, built from
# effectstream/mint-test-tokens). Their ids are therefore per-stack — exactly like the contract
# address used to be — and every consumer that needs one has to LEARN it at container start.
#
# ── WHY THIS FILE PARSES NOTHING ─────────────────────────────────────────────
# `images/issuer/m1/registry.ts` is the ONE reader of `metadata.undeployed.json` in this
# repository: it validates the file against the pinned tree's own JSON schema AND against the
# semantic validator the faucet site runs, and it is what `./verify.sh` and an operator both
# read the six ids from. A second parser here — in shell, over a 40 kB nested JSON document —
# would be a second definition of "what this stack's tokens are", and the two would drift.
#
# So the ISSUER publishes a shell-sourceable projection of its own reader's output,
# `tokens.env`, on the shared `issuer-tokens` volume (images/issuer/m1/tokens-env.ts, run by
# entrypoint-deploy.sh on both the deploy and the resume path), and this file SOURCES it. The
# format is deliberately dull: `NAME=value` with values restricted to 64-hex, small integers,
# lowercase symbols and ISO timestamps, all validated after sourcing — so a corrupt or
# truncated file fails here, by name, instead of becoming a token id nobody can explain.
#
# ── WHAT IT EXPORTS ──────────────────────────────────────────────────────────
#   ISSUER_TOKENS_REVISION       the registry revision these ids came from (64 hex)
#   ISSUER_TOKENS_GENERATED_AT   when the registry was published (ISO 8601)
#   ISSUER_TOKENS_NAMES          the six kernel names, canonical order, space-separated
#   ISSUER_TOKEN_ID_<NAME>       the 64-hex token id (the kernel calls it a colour)
#   ISSUER_TOKEN_DECIMALS_<NAME> 8 / 18 / 6 — per token, NOT 6 everywhere any more
#   ISSUER_TOKEN_PRIVACY_<NAME>  shielded | unshielded
#   ISSUER_TOKEN_SYMBOL_<NAME>   twBTC, twETH, …
#   ISSUER_TOKEN_ADDRESS_<NAME>  the deployed token contract's address
#
# ── AND WHAT IT NEVER DOES ───────────────────────────────────────────────────
# It does not default a token id. A consumer that cannot find its token must fail with the
# name it was looking for: an offer posted against a silently-wrong colour is accepted by the
# kernel, unpriceable, unsponsorable and invisible in every panel — the exact class of silent
# failure this stack keeps paying to remove.
#
# Requires log()/die() from entrypoint-common.sh, which every caller sources first.

# The DIRECTORY, never the file: `tokens-env.ts` publishes atomically (write to a temp file in
# the same directory, then rename), which replaces the inode — a single-file bind mount can
# stay attached to the previous snapshot. Same rule as the registry itself.
ISSUER_TOKENS_DIR="${ISSUER_TOKENS_DIR:-/srv/issuer-tokens}"
ISSUER_TOKENS_FILE="${ISSUER_TOKENS_FILE:-${ISSUER_TOKENS_DIR}/tokens.env}"

# The six kernel names, in the pinned issuer tree's canonical order. Stated here so that a
# tokens.env with five entries is a failure rather than a shorter list.
ISSUER_TOKEN_NAMES_EXPECTED="TWBTC TWETH TWUSDC TWUSDM UTWUSDC UTWBTC"

# load_issuer_tokens [timeout_s] — wait for tokens.env, source it, validate it.
#
# The wait exists for the case compose cannot express. Most consumers are gated on
# `issuer-deploy: service_completed_successfully` and see the file immediately; a container
# restarted by its own restart policy while the issuer is still publishing would not.
load_issuer_tokens() {
  local timeout="${1:-${ISSUER_TOKENS_WAIT_TIMEOUT_S:-3600}}" waited=0

  while [ ! -f "${ISSUER_TOKENS_FILE}" ]; do
    waited=$(( waited + 2 ))
    if [ "${waited}" -ge "${timeout}" ]; then
      log "TIMEOUT after ${timeout}s waiting for ${ISSUER_TOKENS_FILE}"
      log "the issuer-deploy one-shot has published no token ids. This profile needs the"
      log "\`issuer\` profile: ./up.sh --with offerfiles --with issuer …"
      die "no issuer token ids"
    fi
    [ "${waited}" -eq 2 ] && log "waiting for ${ISSUER_TOKENS_FILE} (up to ${timeout}s)"
    sleep 2
  done

  # ── the file must be a projection, not a script ───────────────────────────
  # It is SOURCED, so anything in it runs. It is written by a first-party one-shot on a volume
  # only this stack's containers can reach, and it is still checked line by line first: a
  # sourced file that is allowed to contain arbitrary shell is a foothold, and refusing one
  # costs four lines.
  local bad
  bad="$(grep -vE '^(#|$|[A-Z][A-Z0-9_]*=[A-Za-z0-9_.:@+-]*$|[A-Z][A-Z0-9_]*="[A-Za-z0-9_. :@+-]*"$)' \
           "${ISSUER_TOKENS_FILE}" | head -3 || true)"
  if [ -n "${bad}" ]; then
    log "${ISSUER_TOKENS_FILE} is not a plain NAME=value projection. First offending line(s):"
    printf '%s\n' "${bad}" | sed 's/^/    /' >&2
    die "refusing to source ${ISSUER_TOKENS_FILE}"
  fi

  # shellcheck disable=SC1090  # runtime path, published by the issuer-deploy one-shot
  . "${ISSUER_TOKENS_FILE}"

  case "${ISSUER_TOKENS_REVISION:-}" in
    ????????????????????????????????????????????????????????????????) : ;;
    *) die "${ISSUER_TOKENS_FILE} carries no 64-hex ISSUER_TOKENS_REVISION" ;;
  esac

  local name id decimals
  for name in ${ISSUER_TOKEN_NAMES_EXPECTED}; do
    eval "id=\${ISSUER_TOKEN_ID_${name}:-}"
    eval "decimals=\${ISSUER_TOKEN_DECIMALS_${name}:-}"
    case "${id}" in
      *[!0-9a-f]*|"") die "${ISSUER_TOKENS_FILE}: ISSUER_TOKEN_ID_${name} is not lowercase hex ('${id}')" ;;
    esac
    [ "${#id}" -eq 64 ] || die "${ISSUER_TOKENS_FILE}: ISSUER_TOKEN_ID_${name} is ${#id} chars, not 64"
    case "${decimals}" in
      ''|*[!0-9]*) die "${ISSUER_TOKENS_FILE}: ISSUER_TOKEN_DECIMALS_${name} is not an integer ('${decimals}')" ;;
    esac
  done

  ISSUER_TOKENS_NAMES="${ISSUER_TOKENS_NAMES:-${ISSUER_TOKEN_NAMES_EXPECTED}}"
  export ISSUER_TOKENS_REVISION ISSUER_TOKENS_GENERATED_AT ISSUER_TOKENS_NAMES
  log "issuer tokens loaded: ${ISSUER_TOKENS_NAMES// /, } (registry revision ${ISSUER_TOKENS_REVISION:0:16}…)"
}

# issuer_token_id <NAME> — the 64-hex id, or a fatal error naming the token.
issuer_token_id() {
  local name value
  name="$(printf '%s' "${1:?issuer_token_id needs a token name}" | tr '[:lower:]' '[:upper:]')"
  eval "value=\${ISSUER_TOKEN_ID_${name}:-}"
  if [ -z "${value}" ]; then
    log "no such issuer token: '${1}'. This stack issues: ${ISSUER_TOKENS_NAMES:-${ISSUER_TOKEN_NAMES_EXPECTED}}"
    die "unknown token ${1}"
  fi
  printf '%s' "${value}"
}

# issuer_token_decimals <NAME>
issuer_token_decimals() {
  local name value
  name="$(printf '%s' "${1:?issuer_token_decimals needs a token name}" | tr '[:lower:]' '[:upper:]')"
  eval "value=\${ISSUER_TOKEN_DECIMALS_${name}:-}"
  if [ -z "${value}" ]; then
    log "no decimals recorded for issuer token '${1}'"
    die "unknown token ${1}"
  fi
  printf '%s' "${value}"
}

# issuer_whole_coin <NAME> — 10^decimals, as a decimal STRING.
#
# STRING ARITHMETIC ON PURPOSE. TWETH has 18 decimals, so one whole coin is 10^18 base units;
# bash arithmetic is 64-bit SIGNED, `$(( 10 ** 18 ))` is 1000000000000000000 and fits, and
# `$(( 10 ** 19 ))` silently overflows to a negative number. A token with 19+ decimals is
# legal in the kernel's schema (`decimals` is checked 0..38), so the shell must never be asked
# to do this multiplication at all — "1" followed by N zeros is exact for every N.
issuer_whole_coin() {
  local decimals i out
  decimals="$(issuer_token_decimals "${1:?issuer_whole_coin needs a token name}")"
  out=1
  i=0
  while [ "${i}" -lt "${decimals}" ]; do
    out="${out}0"
    i=$(( i + 1 ))
  done
  printf '%s' "${out}"
}
