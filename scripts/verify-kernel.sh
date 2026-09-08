#!/usr/bin/env bash
#
# Assertions for the `offerfiles` profile's kernel + batcher — the `kernel` section of
# ./verify.sh.
#
#   ./scripts/verify-kernel.sh
#
# EVERY ASSERTION IS AGAINST WHAT KERNEL `main` ACTUALLY SERVES, checked at the pinned commit.
#
# HISTORY WORTH RECORDING: an EARLIER `main` (before kernel PR #48 merged the whole
# `feat/cow-solver` line into it) served neither `POST /v1/offers/files` nor `GET
# /v1/offers/updates`, and this script's own header used to document that as a fact about "the
# pin". It is no longer one: KERNEL_REF is `main` again (phase G), and `main` now sits 20
# commits beyond that merge — `POST /v1/offers/files`, `requireCurrentBackend` (the sync-lag
# gate `offer-files-read.ts` uses) and `API_RATE_LIMIT_MAX`/`_ALLOWLIST` (env-configurable,
# default 60/min; `/v1/health`, `/v1/health/sync`, `/keys/*`, `/zkir/*`, `/docs*` exempt) are
# all present. None of that changes what THIS script asserts — it never depended on the
# exact-files route or a lag gate — but a header that named them absent would now be wrong.
#
# main ALSO now carries kernel PR #54 (seeded reference asset prices, `GET /v1/prices`, a
# price-feed service — see the `prices` section below) and PR #56 (the batcher's sponsorship
# gate, `BATCHER_SPONSOR_POLICY`/`BATCHER_SPONSOR_UNPRICED`, defaults warn/allow).
#
# What it proves, and why each check is here rather than being assumed:
#
#   health          GET /v1/health answers `{status, synced}`. `synced:true` is the real gate —
#                   the kernel serves the API long before its projection is current, and a book
#                   that is merely reachable is not a book you can trade against.
#   sync detail     GET /v1/health/sync — the per-source breakdown. The Celestia lag is REPORTED
#                   here and nowhere else on main, which is exactly why the DA block cadence is
#                   pinned at 3s (images/celestia/entrypoint.sh, DIVERGENCE 5).
#   midnight config GET /v1/midnight/config answers the four network endpoints — and NO
#                   `contractAddress`. Its absence is asserted, not merely tolerated: kernel #69
#                   removed the field with the contract, and a pin that still served one would
#                   mean KERNEL_REF had moved BACKWARDS while this repository's images, compose
#                   fragments and verify scripts had not.
#   offers API      GET /v1/offers answers a JSON body. Empty is correct on a fresh chain; an
#                   error here means the Postgres half is down even though health is up.
#   known tokens    GET /v1/known-tokens lists the SIX ISSUED colours by name, matched against
#                   the ids the `issuer` profile's own registry reports — a genuine end-to-end
#                   check of issue -> publish -> register -> serve rather than a fixed
#                   expectation, since each colour derives from the contract that token was
#                   deployed at. It also asserts what must NOT be there: no `DEVA`/`DEVB`/`DEVU`
#                   (the deleted faucet's colours), no `USDC`/`USDM` (rows kernel #69 removed
#                   from the seed), and no `TESTTOKEN*`. Skipped with a note when the `issuer`
#                   profile is not part of this bring-up. If `shielded-night` is up too, a
#                   sNight row is expected, priced rather than merely named.
#   issued prices   For the two tokens whose decimals are NOT 6 — TWBTC at 8 and TWETH at 18 —
#                   the per-base-unit price the kernel serves must equal its coin price divided
#                   by 10^decimals, EXACTLY, as decimal strings. That rule was checked for one
#                   token at one decimals value before this pin; it is the whole of what
#                   "decimals-aware" means, and 8 and 18 are where a `Number` would start
#                   losing digits.
#   token decimals  EVERY row of GET /v1/known-tokens carries ITS OWN expected decimals — 6 for
#                   every colour this stack mints or seeds (kernel PR #63's whole-coin line,
#                   where `decimals` DEFAULTS to 6 and every faucet mints whole
#                   coins scaled by 10^6), and the ISSUER's own for its six — TWBTC 8, TWETH 18,
#                   TWUSDC 6, TWUSDM 6, UTWUSDC 6, UTWBTC 8 (00020 PR B; 6 stopped being the
#                   only right answer when this stack gained a token source of its own).
#                   This is ALSO the stale-volume detector: 000-init.sql
#                   runs once against an empty database and has no IF NOT EXISTS, so a `postgres`
#                   volume created under an older KERNEL_REF keeps the old `DEFAULT 0` forever
#                   and merely lies about every price. A row at 0 fails NAMING `./down.sh -v`.
#   (faucet)        THE `faucet` BLOCK IS GONE (00020 PR C). It read the whole-coin ALLOTMENT
#                   out of the running image's pinned tree and asserted the two priced faucet
#                   presets WBTC/WETH. Kernel #69 deleted `docs/src/wallet/mintable.ts`, the
#                   presets and the circuit that minted them; `faucet-probe.ts` went with them.
#                   What replaced it is the `issued prices` block below, which asserts the same
#                   arithmetic rule on tokens that exist.
#   prices          GET /v1/prices?tokens=<NIGHT colour> answers a REAL price (source
#                   feed|seed|manual, never fallback) for `midnight-3` — kernel PR #54's
#                   reference-price table, seeded offline by 000-init.sql with no CoinGecko
#                   network dependency, and REFRESHED from CoinGecko when the `prices` profile
#                   is up (00014). This section is deliberately indifferent to WHICH of the two
#                   is live: `seed` proves the offline seed alone is enough to quote, `feed`
#                   proves the refresh landed, and the arithmetic rule it asserts
#                   (per-base-unit == coin / 10^decimals, exactly) holds on both. The
#                   seeded 2026-09-02 LITERALS in the faucet block below are therefore asserted
#                   only while `source` is `seed`/`fixed` — a live price is supposed to move.
#                   scripts/verify-prices.sh is what proves a refresh actually happened.
#   zk assets       /keys/* and /zkir/* are GONE at this pin and their ABSENCE is asserted.
#                   `packages/node/zk-assets.ts` was deleted by kernel #69 along with the
#                   contract whose proving keys they served, so a 404 here is the correct
#                   answer and a 200 would mean the pin had moved backwards. The SPA's faucet
#                   tab depends on those routes and stays dead until phase D re-points it at the
#                   issuer's own site, which serves the same class of artifact.
#   batcher         GET /health on the batcher answers `{"status":"ok"}`. batcher-sdk 0.103.1
#                   DOES serve a health route (the v9 SDK's did not, which is why the sibling
#                   repository probes `GET /` instead — on main that is a plain Fastify 404 and
#                   would pass against a batcher that never initialised).
#
# Everything runs over the PUBLISHED HOST PORT, deliberately: that is the endpoint a human, the
# SPA or a debugging session actually uses, and an in-container check cannot see a
# loopback-bound listener.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"

require_docker
load_env
# Every fragment, not just offerfiles: `dc exec` must resolve the service, and naming only one
# profile makes compose call every other profile's containers orphans on each invocation.
use_all_profiles

BIND="${HOST_ADDR:-127.0.0.1}"
API="http://${BIND}:${KERNEL_HOST_PORT:-9999}"
BATCHER="http://${BIND}:${BATCHER_HOST_PORT:-3334}"

FAILURES=0
fail() { err "$*"; FAILURES=$(( FAILURES + 1 )); }

# `decimal_shift_left <value> <n>` — EXACT decimal-string division by 10^n — used to be
# defined right here. It MOVED TO scripts/lib/common.sh in 00014, unchanged, because
# scripts/verify-prices.sh needs the identical routine for FED prices and two copies of a
# numeric function that must agree to the last digit (and that both mirror
# packages/database/price-map.ts) is a drift waiting to happen. It is still the same function
# with the same contract; this script simply gets it from the library it already sources.

log "kernel: endpoints"
info "api      ${API}"
info "batcher  ${BATCHER}"

# ── health, and specifically CURRENTNESS ─────────────────────────────────────
echo
log "kernel: health"
HEALTH="$(curl -fsS --max-time 10 "$API/v1/health" 2>/dev/null || true)"
if [[ -z "$HEALTH" ]]; then
  fail "GET /v1/health did not answer — nothing below can be checked"
  exit 1
fi
ok "GET /v1/health answers: ${HEALTH}"

# `synced` is the boolean form of the sync status. Asserted rather than reported: an
# unsynchronised kernel answers every read with a stale or empty book and no error.
if [[ "$HEALTH" == *'"synced":true'* ]]; then
  ok "the kernel reports itself SYNCED"
else
  fail "the kernel is not synced: ${HEALTH}"
fi

SYNC="$(curl -fsS --max-time 10 "$API/v1/health/sync" 2>/dev/null || true)"
if [[ -z "$SYNC" ]]; then
  fail "GET /v1/health/sync did not answer"
else
  SYNC_STATUS="$(printf '%s' "$SYNC" | grep -oE '"status"[[:space:]]*:[[:space:]]*"[a-z]+"' | grep -oE '[a-z]+"$' | tr -d '"' | head -1)"
  if [[ "$SYNC_STATUS" == "ok" ]]; then
    ok "/v1/health/sync status=ok"
  else
    fail "/v1/health/sync status=${SYNC_STATUS:-unreadable} (expected ok)"
  fi
  # REPORTED, not asserted. main has no lag gate, and the absolute numbers depend on how long
  # the stack has been up — but a Celestia lag that keeps growing is the symptom the 3s cadence
  # exists to prevent, and an operator reading this output should be able to see it.
  #
  # `celestia.lag_blocks` is legitimately NULL on this devnet: the kernel derives it from a DA
  # `tip` it does not always resolve, and reports `{current, fetched, tip: null, lag_blocks:
  # null}`. That is the kernel saying "unknown", not this script failing to parse — so the two
  # cases are printed differently, and `current` is shown, which IS always populated.
  CEL_CUR="$(printf '%s' "$SYNC" | sed -nE 's/.*"celestia"[^}]*"current"[[:space:]]*:[[:space:]]*"?([0-9]+)"?.*/\1/p' | head -1)"
  CEL_LAG="$(printf '%s' "$SYNC" | sed -nE 's/.*"celestia"[^}]*"lag_blocks"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' | head -1)"
  MID_LAG="$(printf '%s' "$SYNC" | sed -nE 's/.*"midnight"[^}]*"lag_blocks"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' | head -1)"
  info "celestia: height=${CEL_CUR:-?} lag_blocks=${CEL_LAG:-null (the kernel could not resolve a DA tip)}"
  info "midnight: lag_blocks=${MID_LAG:-?}"
fi

# ── the midnight config, and the field that must NOT be in it ────────────────
#
# Up to `KERNEL_REF=a608fa6…` this block asserted a NON-EMPTY `contractAddress` here and matched
# it against the copy the deploy one-shot persisted on a shared volume. Kernel #69 deleted the
# offer-files contract, `readMidnightContract()` and the field: `GET /v1/midnight/config` now
# answers with the network endpoints alone.
#
# THE ABSENCE IS ASSERTED RATHER THAN TOLERATED. Simply deleting the check would leave nothing
# in this repository that notices a KERNEL_REF moved BACKWARDS onto the faucet line — a pin
# where the kernel expects a contract, `images/offerfiles-kernel` no longer compiles one, and
# the failure surfaces much later inside the sync node. The Dockerfile asserts the same thing
# from the build side; this asserts it from the running API.
echo
log "kernel: midnight config"
CONFIG="$(curl -fsS --max-time 10 "$API/v1/midnight/config" 2>/dev/null || true)"
if [[ -z "$CONFIG" ]]; then
  fail "GET /v1/midnight/config did not answer"
else
  case "${CONFIG:0:1}" in
    '{') ok "GET /v1/midnight/config answers JSON (${#CONFIG} bytes)" ;;
    *)   fail "GET /v1/midnight/config answered something that is not JSON: ${CONFIG:0:120}" ;;
  esac
  # `indexer` and `proofServer` are the two endpoint keys the route has always carried and the
  # SPA reads; naming them keeps this from passing on an empty `{}`.
  CONFIG_MISSING=""
  for key in indexer proofServer; do
    case "$CONFIG" in
      *"\"${key}\""*) : ;;
      *) CONFIG_MISSING="${CONFIG_MISSING} ${key}" ;;
    esac
  done
  if [[ -z "$CONFIG_MISSING" ]]; then
    ok "it carries the network endpoints (indexer, proofServer)"
  else
    fail "GET /v1/midnight/config is missing endpoint key(s):${CONFIG_MISSING} — ${CONFIG:0:200}"
  fi
  if [[ "$CONFIG" == *'"contractAddress"'* ]]; then
    fail "GET /v1/midnight/config still carries a contractAddress. Kernel #69 removed the
          offer-files contract and this field with it, and this repository is built for the pin
          WITHOUT it: images/offerfiles-kernel has no Compact stage, so a kernel that wants a
          contract will not find one. Check KERNEL_REF (expected e3b9388… or later).
          ${CONFIG:0:200}"
  else
    ok "and NO contractAddress — kernel #69 removed the offer-files contract, as this pin expects"
  fi
fi

# ── the book ─────────────────────────────────────────────────────────────────
echo
log "kernel: book"
# CAPTURE, THEN MATCH — never `curl … | grep -q` for a result under `pipefail`: grep closes the
# pipe on its first match, curl dies of SIGPIPE, and the pipeline reports failure.
OFFERS="$(curl -fsS --max-time 10 "$API/v1/offers" 2>/dev/null || true)"
case "${OFFERS:0:1}" in
  '{'|'[') ok "GET /v1/offers answers JSON (${#OFFERS} bytes)" ;;
  '') fail "GET /v1/offers did not answer — the Postgres half is down even though health is up" ;;
  *) fail "GET /v1/offers answered something that is not JSON: ${OFFERS:0:120}" ;;
esac

# ── the SIX ISSUED tokens, matched by colour ─────────────────────────────────
#
# This block asserted THREE MINTED colours up to `KERNEL_REF=a608fa6…`, read out of the
# `minted-tokens.json` the deploy one-shot published on a shared volume. Kernel #69 deleted the
# mint, the file and the volume. The colours are now ISSUED, once per chain, by the `issuer`
# profile, and the same end-to-end property is asserted one step further along the chain:
# issue -> publish the registry -> `issuer-registrar` POSTs -> the kernel serves them.
#
# THE EXPECTATION COMES FROM THE REGISTRY, NEVER FROM A LITERAL. Each token's colour derives
# from the contract it was deployed at, so it is new on every fresh chain; `issuer-registry` is
# this repository's ONE validating reader of that file and its `ISSUER_TOKEN` lines are read
# here exactly as scripts/verify-solver.sh and scripts/verify-poster.sh read them.
#
# WHAT MUST NOT BE THERE is asserted too, and it is not symmetry for its own sake:
#   DEVA/DEVB/DEVU  the deleted faucet's colours. A row means a stale `postgres` volume, i.e. a
#                   database that skipped `000-init.sql` and is therefore wrong about every
#                   price on the stack (`./down.sh -v`).
#   USDC/USDM       placeholder rows kernel #69 DELETED from the seed. Same signature.
#   TESTTOKEN*      upstream's own mint's names. There is no mint at this pin, so a row here
#                   would mean something ran one against this kernel.
echo
log "kernel: known tokens"
KNOWN="$(curl -fsS --max-time 10 "$API/v1/known-tokens" 2>/dev/null || true)"

# The six canonical names, in the pinned issuer registry's own order. Stated here so that FIVE
# rows is a failure rather than a shorter list.
ISSUER_TOKEN_NAMES="TWBTC TWETH TWUSDC TWUSDM UTWUSDC UTWBTC"

# The issuer profile is optional for THIS section: `--with offerfiles` alone is a supported
# bring-up and has no issuer in it. `faucet` is the profile's only always-on service, so its
# presence is what decides between asserting and reporting. (`poster` and `solver` cannot be up
# without `issuer` at this pin — compose refuses to render — so the assertive path is the one
# every interesting stack takes.)
# `issuer_registry_lines` (scripts/lib/common.sh) runs the reporter once and caches it; it is
# empty when the issuer profile is not up, and every host-side verify script reads the six ids
# through it so there is one definition of "what this stack's tokens are".
ISSUER_TOKEN_LINES="$(issuer_registry_lines || true)"

if [[ -z "$KNOWN" ]]; then
  fail "GET /v1/known-tokens did not answer"
elif ! service_present faucet; then
  warn "the issuer profile is not up, so there are no issued colours to match"
  info "bring it up with: ./up.sh --with offerfiles --with issuer"
  info "known-tokens answered: ${KNOWN:0:200}"
elif [[ -z "$ISSUER_TOKEN_LINES" ]]; then
  fail "the issuer profile is up but issuer-registry reported no ISSUER_TOKEN lines —
        the registry is missing or did not validate (scripts/verify-issuer.sh says why)"
else
  MATCHED=0
  MISSING=""
  for NAME in $ISSUER_TOKEN_NAMES; do
    # `|| true` on every extraction, for the reason above.
    COLOUR="$(issuer_token_id "$NAME" || true)"
    if [[ -z "$COLOUR" ]]; then
      MISSING="${MISSING} ${NAME}(not-issued)"
      continue
    fi
    if [[ "$KNOWN" == *"$COLOUR"* ]]; then
      MATCHED=$(( MATCHED + 1 ))
    else
      MISSING="${MISSING} ${NAME}=${COLOUR:0:16}…"
    fi
  done
  if (( MATCHED == 6 )); then
    ok "all six issued colours are listed by /v1/known-tokens"
  else
    fail "/v1/known-tokens lists only ${MATCHED}/6 issued colours; missing:${MISSING}
          (issuer-registrar registers these — check that one-shot's log; up.sh treats its
          failure as fatal, so a miss here means it was never run against this kernel)"
  fi
fi

# ── the names that must NOT be in the registry ───────────────────────────────
#
# Runs whether or not the issuer profile is up: every one of these is wrong on this stack no
# matter which colour carries it. bash 3.2 has no `${var^^}`, hence `tr`; the normalisation is
# the kernel's own (`String(name).trim().toUpperCase().slice(0, 16)`, packages/node/api.ts).
kernel_name() {
  printf '%s' "${1}" \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | tr '[:lower:]' '[:upper:]' \
    | cut -c1-16
}

if [[ -n "$KNOWN" ]]; then
  echo
  log "kernel: retired token names"
  RETIRED_ROWS=""
  STALE_SEED=0
  while IFS= read -r row; do
    case "$row" in
      *'"name":'*) : ;;
      *) continue ;;
    esac
    ROW_NAME="$(printf '%s' "$row" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' | head -1 || true)"
    case "$(kernel_name "${ROW_NAME}")" in
      TESTTOKEN*)          RETIRED_ROWS="${RETIRED_ROWS} ${ROW_NAME}(upstream mint)" ;;
      DEVA|DEVB|DEVU)      RETIRED_ROWS="${RETIRED_ROWS} ${ROW_NAME}(deleted faucet)"; STALE_SEED=1 ;;
      USDC|USDM)           RETIRED_ROWS="${RETIRED_ROWS} ${ROW_NAME}(deleted seed row)"; STALE_SEED=1 ;;
    esac
  done <<< "$(printf '%s' "$KNOWN" | tr '{' '\n')"

  if [[ -z "$RETIRED_ROWS" ]]; then
    ok "no DEVA/DEVB/DEVU, USDC/USDM or TESTTOKEN* row — the registry holds only this pin's tokens"
  elif (( STALE_SEED )); then
    fail "the registry still holds row(s) kernel #69 removed:${RETIRED_ROWS}
          THIS IS THE STALE-VOLUME SIGNATURE. 000-init.sql has no IF NOT EXISTS and runs ONCE
          against an empty database, so a \`postgres\` volume created under an older KERNEL_REF
          keeps the old seed forever and nothing migrates it. ./down.sh -v is the upgrade path
          for this pin — see docs/OPERATIONS.md."
  else
    fail "the registry holds TESTTOKEN* row(s):${RETIRED_ROWS}
          There is no mint at this pin (kernel #69 deleted mint-test-tokens.ts), so something
          ran one against this kernel. ./down.sh -v afterwards: the colours are per chain."
  fi
fi

# ── EVERY REGISTERED TOKEN IS AT ITS OWN DECLARED DECIMALS ───────────────────
#
# Kernel PR #63 (KERNEL_REF c293ebd…) made `known_tokens.decimals` DEFAULT 6 instead of 0 and
# made every faucet mint WHOLE COINS scaled by 10^6. The registry is what turns a base-unit
# amount into a USD price (`asset_prices.price_usd / 10^decimals`), so a single row left at the
# old default silently misprices that colour by a factor of a million — in the SPA, in
# `GET /v1/quote` and in the batcher's sponsorship verdict.
#
# ── 6 IS NO LONGER THE ONLY RIGHT ANSWER (00020 PR B) ────────────────────────
# This check used to assert `decimals == 6` for EVERY row, and that was correct while every
# colour on the stack came from the kernel's own faucet contract. The `issuer` profile issues
# SIX colours that are deliberately not all 6: TWBTC and UTWBTC are 8, TWETH is 18, the other
# three are 6. Asserting 6 for those would fail a stack that is exactly right.
#
# So the sweep now compares each row against its OWN expected value, and the expectation is
# stated rather than read back from the row it is checking:
#
#   * the six canonical issuer names -> the decimals ISSUER_EXPECTED_DECIMALS names below,
#     which are the pinned registry's own (packages/registry/src/tokens.ts) and the same six
#     values scripts/verify-issuer.sh asserts independently;
#   * every other row -> 6, exactly as before.
#
# A row at 0 is STILL the stale-volume signature, for any name.
#
# THIS IS ALSO THE STALE-VOLUME DETECTOR. `packages/database/migrations/000-init.sql` has no
# `IF NOT EXISTS` and runs EXACTLY ONCE, against an empty database. A `postgres` volume created
# under an older KERNEL_REF therefore keeps `decimals DEFAULT 0` and its old seed rows forever,
# and NOTHING migrates it: the stack comes up healthy and merely lies about every price. A row
# at 0 is the signature, so it is named as such here with `./down.sh -v` as the fix, rather
# than being reported as a slow chain or an unregistered colour.
# `<NAME>:<decimals>` for every token whose right answer is not 6. The six canonical
# mint-test-tokens names and the pinned registry's own decimals; scripts/verify-issuer.sh
# asserts the same six against the registry FILE, so a drift between this list and the
# registry fails there rather than passing quietly here.
ISSUER_EXPECTED_DECIMALS="TWBTC:8 TWETH:18 TWUSDC:6 TWUSDM:6 UTWUSDC:6 UTWBTC:8"

# expected_decimals <name> — 6 unless the name is one of the six above.
expected_decimals() {
  local name spec
  name="$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')"
  for spec in $ISSUER_EXPECTED_DECIMALS; do
    if [[ "${spec%%:*}" == "$name" ]]; then
      printf '%s' "${spec#*:}"
      return 0
    fi
  done
  printf '6'
}

if [[ -n "$KNOWN" ]]; then
  echo
  log "kernel: token decimals (6 for this stack's own colours; the issuer's own for its six)"
  DEC_ROWS=0
  DEC_OK=0
  DEC_BAD=""
  DEC_STALE=0
  DEC_NON6=""
  while IFS= read -r row; do
    case "$row" in
      *'"name":'*) : ;;
      *) continue ;;
    esac
    DEC_ROWS=$(( DEC_ROWS + 1 ))
    ROW_NAME="$(printf '%s' "$row" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' | head -1)"
    # `[0-9][0-9]*`, never the GNU-only `[0-9]\+`: BSD sed silently matches nothing (00007 H2).
    ROW_DEC="$(printf '%s' "$row" | sed -n 's/.*"decimals":\([0-9][0-9]*\).*/\1/p' | head -1)"
    ROW_WANT="$(expected_decimals "$ROW_NAME")"
    if [[ "$ROW_DEC" == "$ROW_WANT" ]]; then
      DEC_OK=$(( DEC_OK + 1 ))
      [[ "$ROW_WANT" == "6" ]] || DEC_NON6="${DEC_NON6} ${ROW_NAME}=${ROW_DEC}"
    else
      DEC_BAD="${DEC_BAD} ${ROW_NAME:-<unnamed>}=${ROW_DEC:-none}(want ${ROW_WANT})"
      [[ "$ROW_DEC" == "0" ]] && DEC_STALE=1
    fi
  done <<< "$(printf '%s' "$KNOWN" | tr '{' '\n')"

  if (( DEC_ROWS == 0 )); then
    fail "GET /v1/known-tokens listed no rows at all — nothing is registered on this stack"
  elif (( DEC_OK == DEC_ROWS )); then
    if [[ -n "$DEC_NON6" ]]; then
      ok "all ${DEC_ROWS} registered tokens carry their own declared decimals — 6 for this stack's colours, and${DEC_NON6} for the issuer's"
    else
      ok "all ${DEC_ROWS} registered tokens are at exactly 6 decimals (kernel PR #63's whole-coin line)"
    fi
  elif (( DEC_STALE )); then
    fail "STALE POSTGRES VOLUME: ${DEC_OK}/${DEC_ROWS} tokens carry their expected decimals, and at least one is at the pre-#63 default 0 —${DEC_BAD}
          000-init.sql runs ONCE against an EMPTY database and has no IF NOT EXISTS, so a volume
          created under an older KERNEL_REF keeps decimals DEFAULT 0 and its old seed rows, and
          nothing migrates it. Fix: ./down.sh -v && ./up.sh  (there is nothing to migrate on a devnet)"
  else
    fail "${DEC_OK}/${DEC_ROWS} registered tokens carry their expected decimals; these do not —${DEC_BAD}
          Every colour this stack mints or seeds is 6 (kernel PR #63); the issuer's six are
          8/18/6/6/6/8 (packages/registry/src/tokens.ts). A colour registered at a different
          scale prices as price_usd / 10^decimals and is wrong by that factor."
  fi
fi

# The sNight row — a DIFFERENT one-shot (images/shielded-night/entrypoint-token-name.sh), run
# by up.sh only when BOTH `offerfiles` AND `shielded-night` are up (the profile itself declares
# no dependency on a kernel — spec FR-002/FR-015). Reported, not hard-failed, when
# shielded-night is not part of this bring-up: this script's job is the offerfiles profile,
# and a stack legitimately brought up as `--with offerfiles` alone has nothing to check here.
#
# ── AND SINCE 00015, WHOSE COLOUR IT CARRIES ────────────────────────────────
# The kernel SEEDS a SNIGHT row at the PREVIEW contract's colour (000-init.sql, kernel PR #61),
# which cannot exist on an `undeployed` devnet. The registry one-shot now patches that row with
# this stack's own colour before registering it (images/shielded-night/sql/snight-registry-patch.sql
# — the statement the kernel's own comment prescribes; organizer issues/00012). Two assertions
# keep that honest from THIS side, where the whole registry is in hand:
#   * exactly ONE row is named SNIGHT — a second one would mean the name stopped being UNIQUE,
#     and every `grep -i snight` in this repository would then be reading whichever came first;
#   * the preview colour appears NOWHERE in the registry — a stack that still carries it is a
#     stack whose patch did not run, and the sNight assertions below would pass VACUOUSLY
#     against the phantom row exactly as they did before 00011 PR A.
# The colour is compared against the one DERIVED from this stack's contract in
# verify-shielded-night.sh, which is the only place that can derive it.
SNIGHT_COLOR_FOR_QUOTE=""
PREVIEW_SNIGHT_COLOR="793c29c94f72972bfbd861e8e84e55480ccc8e57a7b74067f35a5672c816f99c"
if service_present shielded-night; then
  # `|| true`: `grep -c` exits 1 when it counts zero, which is a legitimate answer here (it is
  # the failure this block reports) and must not kill the script under `pipefail`.
  SNIGHT_ROW_COUNT="$(printf '%s' "$KNOWN" | tr '{' '\n' | grep -ci '"name":"snight"' || true)"
  if [[ "${SNIGHT_ROW_COUNT:-0}" == "1" ]]; then
    ok "exactly one registry row is named SNIGHT"
  else
    fail "the registry holds ${SNIGHT_ROW_COUNT:-0} rows named SNIGHT, expected exactly 1 — known_tokens.name is UNIQUE, so this stack's registry is not what this repository understands"
  fi
  if printf '%s' "$KNOWN" | grep -q "$PREVIEW_SNIGHT_COLOR"; then
    fail "the kernel's seeded PREVIEW sNight colour ${PREVIEW_SNIGHT_COLOR:0:16}… is still in the registry —
          the shielded-night-token-name one-shot did not patch it (issues/00012). That colour cannot exist on
          an undeployed devnet, so every sNight assertion below would pass against a phantom row.
          Re-run it: docker compose run --rm --no-deps shielded-night-token-name"
  else
    ok "the seeded PREVIEW sNight colour ${PREVIEW_SNIGHT_COLOR:0:16}… is absent from the registry"
  fi
  if [[ -n "$KNOWN" ]] && printf '%s' "$KNOWN" | grep -qi '"name":"snight"'; then
    SNIGHT_ROW="$(printf '%s' "$KNOWN" | tr '{' '\n' | grep -i '"name":"snight"' | head -1)"
    SNIGHT_ROW_DECIMALS="$(printf '%s' "$SNIGHT_ROW" | sed -n 's/.*"decimals":\([0-9][0-9]*\).*/\1/p' | head -1)"
    if [[ "$SNIGHT_ROW_DECIMALS" == "6" ]] && printf '%s' "$SNIGHT_ROW" | grep -q '"asset_id":"midnight-3"'; then
      ok "sNight is registered PRICED at exactly 6 decimals, asset_id midnight-3: $(printf '%s' "$SNIGHT_ROW" | grep -oE '"decimals":[0-9]+|"asset_id":"[^"]*"' | tr '\n' ' ')"
    else
      fail "sNight is not priced at exactly 6 decimals / asset_id=midnight-3 (decimals=${SNIGHT_ROW_DECIMALS:-none}): ${SNIGHT_ROW:0:200}"
    fi
    SNIGHT_COLOR_FOR_QUOTE="$(printf '%s' "$SNIGHT_ROW" | sed -n 's/.*"token_color":"\([0-9a-fA-F]\{64\}\)".*/\1/p' | head -1)"
    [[ -n "$SNIGHT_COLOR_FOR_QUOTE" ]] || fail "could not read sNight's token_color off its known-tokens row: ${SNIGHT_ROW:0:200}"
  else
    fail "shielded-night is up but /v1/known-tokens names no sNight row — the shielded-night-token-name one-shot did not run or failed"
  fi
else
  info "shielded-night profile not up on this bring-up — nothing to check for the sNight row"
fi

# ── the quote, book-chain-INDEPENDENT (runs even with SHIELDED_NIGHT_SKIP_BOOK=1) ────
# The `book` subsection of verify-shielded-night.sh also asserts this, but that subsection is
# entirely SKIPPED under SHIELDED_NIGHT_SKIP_BOOK=1 (phase G) — this is the one place the
# 1:1 quote claim is proven on every bring-up that has both profiles up, book or no book.
if [[ -n "$SNIGHT_COLOR_FOR_QUOTE" ]]; then
  echo
  log "kernel: sNight<->NIGHT quote"
  NIGHT_COLOR_Q="0000000000000000000000000000000000000000000000000000000000000000"
  QUOTE="$(curl -fsS --max-time 20 "$API/v1/quote?from_token=${SNIGHT_COLOR_FOR_QUOTE}&to_token=${NIGHT_COLOR_Q}&from_amount=1000000" 2>/dev/null || true)"
  if printf '%s' "$QUOTE" | grep -q '"market_rate":1[,}]'; then
    ok "GET /v1/quote sNight->NIGHT market_rate is exactly 1"
  else
    fail "GET /v1/quote sNight->NIGHT is not exactly 1:1: ${QUOTE:0:300}"
  fi
fi

# ── reference prices (kernel PR #54) ──────────────────────────────────────────
# GET /v1/prices?tokens= is REQUIRED and bounded (Q-11 of the kernel's own plan), so this asks
# for exactly NIGHT's own colour (0x00…00, seeded unconditionally) rather than the unfiltered
# form main no longer serves. A `source` of `feed` or `seed` (never `fallback`) is what "this
# stack has a REAL reference price for NIGHT" means — `fallback` is the $1 unknown-token path
# and would mean the seed migration did not run. Both are accepted on purpose: `seed` says the
# offline seed alone is enough to quote (which is why the `prices` profile is optional), and
# `feed` says the 00014 refresh landed. Which one is live is not this section's business.
echo
log "kernel: prices"
NIGHT_COLOR="0000000000000000000000000000000000000000000000000000000000000000"
PRICES="$(curl -fsS --max-time 10 "$API/v1/prices?tokens=${NIGHT_COLOR}" 2>/dev/null || true)"
if [[ -z "$PRICES" ]]; then
  fail "GET /v1/prices?tokens=<NIGHT> did not answer"
else
  # Two DIFFERENT records both carry "asset_id":"midnight-3" — the top-level `assets[]` entry
  # (the COIN price, e.g. 0.01918181 USD) and the `tokens[]` entry for NIGHT's own colour (the
  # PER-BASE-UNIT price, already divided by 10^decimals server-side). Disambiguated by the
  # presence of `token_color`, which only the second carries.
  NIGHT_TOKEN_RECORD="$(printf '%s' "$PRICES" | tr '{' '\n' | grep -E '"token_color":"0{64}"' | head -1)"
  ASSET_RECORD="$(printf '%s' "$PRICES" | tr '{' '\n' | grep '"asset_id":"midnight-3"' | grep -v '"token_color"' | head -1)"
  if [[ -z "$NIGHT_TOKEN_RECORD" ]]; then
    fail "GET /v1/prices?tokens=<NIGHT> has no tokens[] entry for NIGHT's colour: ${PRICES:0:300}"
  else
    NIGHT_TOKEN_SOURCE="$(printf '%s' "$NIGHT_TOKEN_RECORD" | sed -n 's/.*"source":"\([a-z]*\)".*/\1/p' | head -1)"
    NIGHT_TOKEN_DECIMALS="$(printf '%s' "$NIGHT_TOKEN_RECORD" | sed -n 's/.*"decimals":\([0-9][0-9]*\).*/\1/p' | head -1)"
    NIGHT_TOKEN_PRICE="$(printf '%s' "$NIGHT_TOKEN_RECORD" | sed -n 's/.*"price_usd":"\([0-9.]*\)".*/\1/p' | head -1)"
    case "$NIGHT_TOKEN_SOURCE" in
      feed|seed|manual) ok "GET /v1/prices reports a real (non-fallback) price for NIGHT: source=${NIGHT_TOKEN_SOURCE}" ;;
      *) fail "GET /v1/prices did not report a seeded/fed price for NIGHT (source=${NIGHT_TOKEN_SOURCE:-none}): ${NIGHT_TOKEN_RECORD:0:200}" ;;
    esac
    # Q14's fix, asserted directly rather than mirrored: NIGHT must be EXACTLY 6 decimals
    # (1 NIGHT = 10^6 Stars — STARS_PER_NIGHT in midnight-ledger/ledger/src/structure.rs), not
    # merely "whatever the kernel currently says" (that was phase G's weaker, self-consistent-
    # only check, which measured 0 and was wrong — question Q14).
    if [[ "$NIGHT_TOKEN_DECIMALS" == "6" ]]; then
      ok "NIGHT is registered at exactly 6 decimals"
    else
      fail "NIGHT is registered at ${NIGHT_TOKEN_DECIMALS:-none} decimals, expected exactly 6 (kernel PR #60 / Q14) — KERNEL_REF may be pinned before the fix"
    fi
    # NIGHT's price PER BASE UNIT must equal its seeded COIN price / 10^decimals, EXACTLY —
    # read both exact-decimal strings the kernel returns and compare them as STRINGS (never as
    # floats: bash has no float arithmetic at all, and that is deliberately not worked around
    # here, since a float comparison is exactly the class of bug this assertion exists to rule
    # out on the kernel side too — see packages/database/price-map.ts's tokenPriceFromAsset()).
    if [[ -z "$ASSET_RECORD" ]]; then
      fail "GET /v1/prices has no assets[] entry for midnight-3 — cannot cross-check NIGHT's per-base-unit price"
    elif [[ -z "$NIGHT_TOKEN_PRICE" || -z "$NIGHT_TOKEN_DECIMALS" ]]; then
      fail "could not read NIGHT's tokens[] price_usd/decimals to cross-check: ${NIGHT_TOKEN_RECORD:0:200}"
    else
      ASSET_PRICE="$(printf '%s' "$ASSET_RECORD" | sed -n 's/.*"price_usd":"\([0-9.]*\)".*/\1/p' | head -1)"
      if [[ -z "$ASSET_PRICE" ]]; then
        fail "could not read midnight-3's coin price_usd off assets[]: ${ASSET_RECORD:0:200}"
      else
        EXPECTED_NIGHT_PRICE="$(decimal_shift_left "$ASSET_PRICE" "$NIGHT_TOKEN_DECIMALS")"
        if [[ "$NIGHT_TOKEN_PRICE" == "$EXPECTED_NIGHT_PRICE" ]]; then
          ok "NIGHT's per-base-unit price (${NIGHT_TOKEN_PRICE}) == its coin price (${ASSET_PRICE}) / 10^${NIGHT_TOKEN_DECIMALS}, exactly"
        else
          fail "NIGHT's per-base-unit price is ${NIGHT_TOKEN_PRICE}, expected ${ASSET_PRICE} / 10^${NIGHT_TOKEN_DECIMALS} = ${EXPECTED_NIGHT_PRICE} exactly"
        fi
      fi
    fi
  fi
fi

# ── THE DECIMALS-AWARE PRICE RULE, on tokens that are not 6 decimals ─────────
#
# WHAT THIS REPLACED. Up to `KERNEL_REF=a608fa6…` this was the `faucet` block: it read the
# whole-coin ALLOTMENT out of the running image's own pinned tree (`docs/src/wallet/mintable.ts`,
# 1 000 coins = 1 000 000 000 base units), registered the two priced faucet presets WBTC/WETH
# through `faucet-probe.ts`, and asserted their per-base-unit prices as exact decimal strings.
# Kernel #69 deleted the circuit, the presets, `mintable.ts` and the probe.
#
# WHAT SURVIVES IS THE ARITHMETIC RULE, and it is the one that matters:
#
#     price per base unit  ==  the asset's COIN price  /  10^decimals,  EXACTLY
#
# It was previously only ever checked at ONE value of `decimals` — 6, for every colour on the
# stack. This stack now issues tokens at 8 and 18, which is precisely where the rule stops being
# a formality: 10^18 exceeds 2^53, so any implementation that touched a float would start losing
# digits here, and a mispriced token is invisible (it makes every quote, every sponsorship
# verdict and every SPA figure quietly wrong rather than failing).
#
# Compared as STRINGS with `decimal_shift_left` (scripts/lib/common.sh), never as numbers: bash
# has no float arithmetic, and that is deliberately not worked around — a float comparison is
# exactly the class of bug this assertion exists to rule out on the kernel side too (see
# packages/database/price-map.ts's `tokenPriceFromAsset()`). scripts/verify-prices.sh applies
# the same helper to FED values.
#
# THE COIN PRICE IS READ FROM THE KERNEL'S OWN assets[] ROW, never hard-coded: whether it is
# `seed` (000-init.sql's offline capture) or `feed` (a CoinGecko refresh, the `prices` profile)
# the rule holds identically, and a live price is supposed to move.
if [[ -n "$KNOWN" ]] && [[ -n "$ISSUER_TOKEN_LINES" ]]; then
  echo
  log "kernel: issued-token prices (per base unit == coin / 10^decimals, exactly)"

  # TWBTC (8) and TWETH (18) are the two whose decimals are NOT 6, and the two the price feed
  # actually prices (bitcoin, ethereum). Together they are the poster's and the maker's pair, so
  # a failure here is a failure of the very quote those services depend on.
  PRICED_CHECKED=0
  for spec in "TWBTC:8:bitcoin" "TWETH:18:ethereum"; do
    P_NAME="${spec%%:*}"
    P_REST="${spec#*:}"
    P_WANT_DEC="${P_REST%%:*}"
    P_ASSET="${P_REST#*:}"
    P_COLOUR="$(issuer_token_id "$P_NAME" || true)"
    if [[ -z "$P_COLOUR" ]]; then
      fail "the issuer registry reports no id for ${P_NAME} — cannot check its price"
      continue
    fi
    PP="$(curl -fsS --max-time 15 "$API/v1/prices?tokens=${P_COLOUR}" 2>/dev/null || true)"
    if [[ -z "$PP" ]]; then
      fail "GET /v1/prices for ${P_NAME} (${P_COLOUR:0:16}…) did not answer"
      continue
    fi
    # Two DIFFERENT records carry the same asset_id: the top-level assets[] entry (the COIN
    # price) and the tokens[] entry (the PER-BASE-UNIT price, divided server-side). Only the
    # second carries `token_color`, which is how they are told apart.
    P_TOKEN_ROW="$(printf '%s' "$PP" | tr '{' '\n' | grep -E "\"token_color\":\"${P_COLOUR}\"" | head -1 || true)"
    P_ASSET_ROW="$(printf '%s' "$PP" | tr '{' '\n' | grep "\"asset_id\":\"${P_ASSET}\"" | grep -v '"token_color"' | head -1 || true)"
    if [[ -z "$P_TOKEN_ROW" ]]; then
      fail "GET /v1/prices has no tokens[] row for ${P_NAME} (${P_COLOUR:0:16}…): ${PP:0:300}"
      continue
    fi
    if [[ -z "$P_ASSET_ROW" ]]; then
      fail "GET /v1/prices has no assets[] row for ${P_ASSET} — ${P_NAME} is registered without
            an asset_id, so it cannot be priced. issuer-registrar writes that column; check it."
      continue
    fi
    P_DEC="$(printf '%s' "$P_TOKEN_ROW" | sed -n 's/.*"decimals":\([0-9][0-9]*\).*/\1/p' | head -1 || true)"
    P_UNIT="$(printf '%s' "$P_TOKEN_ROW" | sed -n 's/.*"price_usd":"\([0-9.]*\)".*/\1/p' | head -1 || true)"
    P_COIN="$(printf '%s' "$P_ASSET_ROW" | sed -n 's/.*"price_usd":"\([0-9.]*\)".*/\1/p' | head -1 || true)"
    P_SOURCE="$(printf '%s' "$P_TOKEN_ROW" | sed -n 's/.*"source":"\([a-z-]*\)".*/\1/p' | head -1 || true)"
    if [[ "$P_DEC" != "$P_WANT_DEC" ]]; then
      fail "${P_NAME} is priced at ${P_DEC:-none} decimals, expected exactly ${P_WANT_DEC} —
            the kernel row's decimals disagree with the issuer's registry"
      continue
    fi
    if [[ -z "$P_UNIT" || -z "$P_COIN" ]]; then
      fail "could not read ${P_NAME}'s per-base-unit / coin price_usd: ${P_TOKEN_ROW:0:200}"
      continue
    fi
    case "$P_SOURCE" in
      feed|seed|manual|fixed) : ;;
      *)
        # `fallback` is the deterministic colour-hash demo value, not a market price, and the
        # sponsorship gate treats it as unpriced. It must not pass.
        fail "${P_NAME}'s price has source='${P_SOURCE:-none}' — expected seed/feed/manual/fixed.
              'fallback' means this colour is not mapped to ${P_ASSET}: issuer-registrar writes
              the asset_id, so check that one-shot's log."
        continue ;;
    esac
    P_EXPECTED="$(decimal_shift_left "$P_COIN" "$P_DEC")"
    PRICED_CHECKED=$(( PRICED_CHECKED + 1 ))
    if [[ "$P_UNIT" == "$P_EXPECTED" ]]; then
      ok "${P_NAME} per base unit is ${P_UNIT} == ${P_COIN} / 10^${P_DEC}, exactly (source=${P_SOURCE})"
    else
      fail "${P_NAME}'s per-base-unit price is ${P_UNIT}, expected ${P_COIN} / 10^${P_DEC} = ${P_EXPECTED}
            exactly (source=${P_SOURCE})"
    fi
  done
  if (( PRICED_CHECKED == 2 )); then
    ok "the decimals-aware price rule holds at BOTH 8 and 18 decimals"
  fi
fi

# ── ZK assets ────────────────────────────────────────────────────────────────
echo
log "kernel: zk assets"
# THE EXPECTATION IS INVERTED AT THIS PIN (00020 PR C). These routes served the proving keys
# and the ZK IR of the offer-files contract's `mint_shielded` circuit, and this block asserted
# they answered 200 with bytes. Kernel #69 deleted `packages/node/zk-assets.ts` — the whole
# `registerZkAssetRoutes(server)` call is gone from `packages/node/api.ts` — along with the
# contract they belonged to. So a 200 here would mean KERNEL_REF had moved BACKWARDS onto the
# faucet line, on a stack whose kernel image no longer compiles a contract at all.
#
# A REAL asset path, not the bare `/keys/` prefix, for the same reason it was a real path
# before: an unresolvable file and an unmounted route both 404, so probing the prefix proves
# nothing in either direction. What makes the assertion meaningful is that this exact path was
# served, with bytes, at the previous pin.
#
# WHAT THIS COSTS, stated rather than buried: the zswap-da SPA's Faucet tab fetches proving keys
# from `/keys/*`, so it is DEAD until phase D re-points it at the issuer's own site — which
# serves the same class of artifact for the six issued tokens. docs/KNOWN-LIMITATIONS.md.
for asset in "/keys/mint_shielded.prover" "/keys/mint_shielded.verifier" "/zkir/mint_shielded.bzkir"; do
  read -r code size <<<"$(curl -s --max-time 20 -o /dev/null -w '%{http_code} %{size_download}' "${API}${asset}" 2>/dev/null || echo '000 0')"
  if [[ "$code" == "404" ]]; then
    ok "${asset} is GONE (HTTP 404) — kernel #69 removed the ZK asset routes, as this pin expects"
  elif [[ "$code" == "200" ]]; then
    fail "${asset} is still SERVED (${size} bytes). Kernel #69 deleted packages/node/zk-assets.ts
          with the contract those keys belong to, and this repository is built for the pin
          WITHOUT them — images/offerfiles-kernel has no Compact stage. Check KERNEL_REF."
  else
    warn "${asset} answered HTTP ${code} rather than 404 — expected gone at this pin"
  fi
done

# ── the batcher ──────────────────────────────────────────────────────────────
echo
log "batcher"
BHEALTH="$(curl -fsS --max-time 10 "$BATCHER/health" 2>/dev/null || true)"
if [[ "$BHEALTH" == *'"status":"ok"'* ]]; then
  ok "batcher GET /health: ${BHEALTH}"
elif [[ -n "$BHEALTH" ]]; then
  fail "batcher /health answered without status=ok: ${BHEALTH:0:200}"
else
  fail "batcher /health did not answer on ${BATCHER}"
fi
# isInitialized false means the process is up but its wallet has not bootstrapped, which is the
# state in which every gasless submission fails. Reported separately so the two are not confused.
if [[ "$BHEALTH" == *'"isInitialized":true'* ]]; then
  ok "batcher reports itself initialised"
elif [[ -n "$BHEALTH" ]]; then
  fail "batcher is serving but NOT initialised — gasless submission will fail: ${BHEALTH:0:200}"
fi

echo
if (( FAILURES == 0 )); then
  ok "verify-kernel.sh: all checks passed"
  exit 0
fi
err "verify-kernel.sh: ${FAILURES} check(s) failed"
exit 1
