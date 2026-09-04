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
#   contract        GET /v1/midnight/config carries a non-empty contract address. This is the
#                   one route that reads MIDNIGHT_CONTRACT_ADDRESS as a direct fallback, so a
#                   non-empty answer proves the deploy one-shot's handoff reached the kernel.
#   offers API      GET /v1/offers answers a JSON body. Empty is correct on a fresh chain; an
#                   error here means the Postgres half is down even though health is up.
#   known tokens    GET /v1/known-tokens lists the dev tokens the deploy one-shot minted, matched
#                   BY COLOUR against the minted-tokens.json it published. Colours derive from
#                   the deployed contract address, so this is a genuine end-to-end check of
#                   deploy -> mint -> publish -> name -> serve, not a fixed expectation. If the
#                   shielded-night profile is ALSO up, a sNight row is expected too, priced
#                   (decimals + asset_id) rather than merely named — reported, not hard-failed,
#                   when that profile is not part of this bring-up.
#   token decimals  EVERY row of GET /v1/known-tokens is at exactly 6 decimals — kernel PR #63's
#                   whole-coin line, where `decimals` DEFAULTS to 6 and every faucet mints whole
#                   coins scaled by 10^6. This is ALSO the stale-volume detector: 000-init.sql
#                   runs once against an empty database and has no IF NOT EXISTS, so a `postgres`
#                   volume created under an older KERNEL_REF keeps the old `DEFAULT 0` forever
#                   and merely lies about every price. A row at 0 fails NAMING `./down.sh -v`.
#   faucet          The ALLOTMENT is read out of the RUNNING image's own pinned tree
#                   (docs/src/wallet/mintable.ts) and must be exactly 1 000 whole coins =
#                   1_000_000_000 base units at 6 decimals; then the two priced faucet presets
#                   (WBTC -> bitcoin, WETH -> ethereum), whose colours derive from the deployed
#                   contract address and so cannot be seeded, are registered idempotently at 6
#                   decimals and their PER-BASE-UNIT prices asserted as exact decimal strings
#                   (0.077387 and 0.00239328). See images/offerfiles-kernel/faucet-probe.ts.
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
#   zk assets       /keys/* is mounted — the browser prover fetches from there.
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

# ── the contract identity ────────────────────────────────────────────────────
echo
log "kernel: contract"
CONFIG="$(curl -fsS --max-time 10 "$API/v1/midnight/config" 2>/dev/null || true)"
KERNEL_ADDR="$(printf '%s' "$CONFIG" | grep -oE '"contractAddress"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]+"' | grep -oE '[0-9a-fA-F]{16,}' | head -1)"
if [[ -n "$KERNEL_ADDR" ]]; then
  ok "offer-files contract ${KERNEL_ADDR}"
else
  fail "/v1/midnight/config carries no contract address: ${CONFIG:0:200}"
fi

# The SAME address must be the one persisted on the share volume. If they ever diverge, some
# path other than the one-shot deployed a contract — the exact failure the one-shot exists to
# prevent, and one that is invisible from the API alone.
PERSISTED="$(dc exec -T kernel sh -c 'cat /srv/offerfiles-deploy/contract-offer-files.undeployed.json 2>/dev/null' 2>/dev/null || true)"
PERSISTED_ADDR="$(printf '%s' "$PERSISTED" | grep -oE '"contractAddress"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]+"' | grep -oE '[0-9a-fA-F]{16,}' | head -1)"
if [[ -z "$PERSISTED_ADDR" ]]; then
  warn "could not read the persisted contract address from the share volume"
elif [[ "$PERSISTED_ADDR" == "$KERNEL_ADDR" ]]; then
  ok "the served address matches the one persisted by the deploy one-shot"
else
  fail "the kernel serves ${KERNEL_ADDR} but the share volume holds ${PERSISTED_ADDR} — something
        other than offerfiles-deploy deployed a contract"
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

# ── the minted dev tokens, matched by colour ─────────────────────────────────
echo
log "kernel: known tokens"
MINTED="$(dc exec -T kernel sh -c 'cat /srv/offerfiles-deploy/minted-tokens.json 2>/dev/null' 2>/dev/null || true)"
KNOWN="$(curl -fsS --max-time 10 "$API/v1/known-tokens" 2>/dev/null || true)"
if [[ -z "$KNOWN" ]]; then
  fail "GET /v1/known-tokens did not answer"
elif [[ -z "$MINTED" ]]; then
  # The mint is non-fatal by design in the deploy one-shot, so its absence is a warning here and
  # a failure nowhere: the stack is usable without demo tokens.
  warn "the deploy one-shot published no minted-tokens.json, so there are no colours to match"
  info "known-tokens answered: ${KNOWN:0:200}"
else
  MATCHED=0
  MISSING=""
  for key in shieldedA shieldedB unshielded; do
    COLOUR="$(printf '%s' "$MINTED" | sed -nE "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"([0-9a-fA-F]+)\".*/\1/p" | head -1)"
    if [[ -z "$COLOUR" ]]; then
      MISSING="${MISSING} ${key}(not-minted)"
      continue
    fi
    if [[ "$KNOWN" == *"$COLOUR"* ]]; then
      MATCHED=$(( MATCHED + 1 ))
    else
      MISSING="${MISSING} ${key}=${COLOUR}"
    fi
  done
  if (( MATCHED == 3 )); then
    ok "all three minted dev-token colours are listed by /v1/known-tokens"
  else
    # This is the offerfiles-token-names one-shot's job. Upstream's mint script tries to do it
    # against the pre-/v1 path `/api/known-tokens` and swallows the 404, which is why that
    # one-shot exists at all — so a miss here means it did not run or did not succeed.
    fail "/v1/known-tokens lists only ${MATCHED}/3 minted colours; missing:${MISSING}
          (offerfiles-token-names registers these — check that one-shot's logs)"
  fi
fi

# ── THE WHOLE-COIN LINE: every registered token is at 6 decimals ─────────────
#
# Kernel PR #63 (KERNEL_REF c293ebd…) made `known_tokens.decimals` DEFAULT 6 instead of 0 and
# made every faucet mint WHOLE COINS scaled by 10^6. The registry is what turns a base-unit
# amount into a USD price (`asset_prices.price_usd / 10^decimals`), so a single row left at the
# old default silently misprices that colour by a factor of a million — in the SPA, in
# `GET /v1/quote` and in the batcher's sponsorship verdict.
#
# THIS IS ALSO THE STALE-VOLUME DETECTOR. `packages/database/migrations/000-init.sql` has no
# `IF NOT EXISTS` and runs EXACTLY ONCE, against an empty database. A `postgres` volume created
# under an older KERNEL_REF therefore keeps `decimals DEFAULT 0` and its old seed rows forever,
# and NOTHING migrates it: the stack comes up healthy and merely lies about every price. A row
# at 0 is the signature, so it is named as such here with `./down.sh -v` as the fix, rather
# than being reported as a slow chain or an unregistered colour.
if [[ -n "$KNOWN" ]]; then
  echo
  log "kernel: token decimals (the whole-coin line)"
  DEC_ROWS=0
  DEC_OK=0
  DEC_BAD=""
  DEC_STALE=0
  while IFS= read -r row; do
    case "$row" in
      *'"name":'*) : ;;
      *) continue ;;
    esac
    DEC_ROWS=$(( DEC_ROWS + 1 ))
    ROW_NAME="$(printf '%s' "$row" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' | head -1)"
    # `[0-9][0-9]*`, never the GNU-only `[0-9]\+`: BSD sed silently matches nothing (00007 H2).
    ROW_DEC="$(printf '%s' "$row" | sed -n 's/.*"decimals":\([0-9][0-9]*\).*/\1/p' | head -1)"
    if [[ "$ROW_DEC" == "6" ]]; then
      DEC_OK=$(( DEC_OK + 1 ))
    else
      DEC_BAD="${DEC_BAD} ${ROW_NAME:-<unnamed>}=${ROW_DEC:-none}"
      [[ "$ROW_DEC" == "0" ]] && DEC_STALE=1
    fi
  done <<< "$(printf '%s' "$KNOWN" | tr '{' '\n')"

  if (( DEC_ROWS == 0 )); then
    fail "GET /v1/known-tokens listed no rows at all — nothing is registered on this stack"
  elif (( DEC_OK == DEC_ROWS )); then
    ok "all ${DEC_ROWS} registered tokens are at exactly 6 decimals (kernel PR #63's whole-coin line)"
  elif (( DEC_STALE )); then
    fail "STALE POSTGRES VOLUME: ${DEC_OK}/${DEC_ROWS} tokens are at 6 decimals, and at least one is at the pre-#63 default 0 —${DEC_BAD}
          000-init.sql runs ONCE against an EMPTY database and has no IF NOT EXISTS, so a volume
          created under an older KERNEL_REF keeps decimals DEFAULT 0 and its old seed rows, and
          nothing migrates it. Fix: ./down.sh -v && ./up.sh  (there is nothing to migrate on a devnet)"
  else
    fail "${DEC_OK}/${DEC_ROWS} registered tokens are at 6 decimals; these are not —${DEC_BAD}
          Every colour this stack mints or seeds is 6 (kernel PR #63). A colour registered at a
          different scale prices as price_usd / 10^decimals and is wrong by that factor."
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

# ── the whole-coin FAUCET, and the two preset colours it mints ───────────────
#
# Two things kernel PR #63 specifies, neither of which any other section can see:
#
#   1. THE ALLOTMENT. One faucet press is 1 000 WHOLE COINS = 1_000_000_000 base units at 6
#      decimals. The number is read out of the RUNNING kernel image's own pinned tree
#      (docs/src/wallet/mintable.ts — the single definition the SPA faucet, the deploy mint and
#      the offer poster all import), never re-declared here, so this asserts what the pinned
#      commit ships rather than what someone remembered about it.
#   2. THE TWO PRICED PRESETS. WBTC and WETH are the faucet names the kernel's built-in map
#      prices (WBTC -> bitcoin, WETH -> ethereum). Their colours derive from the deployed
#      contract address, so 000-init.sql cannot seed them; the probe registers them (with an
#      explicit decimals: 6, exactly the body the SPA sends after a mint) and this section then
#      asserts the per-base-unit prices the whole-coin line implies, as EXACT DECIMAL STRINGS:
#        WBTC  77387    / 10^6 = 0.077387
#        WETH  2393.28  / 10^6 = 0.00239328
#      Those two coin prices are the values seeded by packages/database/migrations/000-init.sql
#      at KERNEL_REF; the expectation is DERIVED from the assets[] row the kernel itself serves,
#      not hard-coded, and then cross-checked against the literal the spec names — but ONLY
#      while the row is still the seed. With the 00014 `prices` profile up, a CoinGecko refresh
#      moves both coin prices and flips `source` to `feed`; the derived exactness rule still
#      holds (and is still asserted), and the literal becomes context rather than an
#      expectation. See the `case "$P_SOURCE"` below.
#
# The probe mints nothing, holds no wallet and signs nothing — it is a derivation plus two
# idempotent registry POSTs, so it is safe on every ./verify.sh run.
if [[ -n "$KERNEL_ADDR" ]]; then
  echo
  log "kernel: faucet (whole coins)"
  PROBE="$(dc exec -T -e "FAUCET_PROBE_CONTRACT=${KERNEL_ADDR}" -e 'KERNEL_API_URL=http://127.0.0.1:9999' \
             kernel bun run /usr/local/lib/offerfiles/faucet-probe.ts 2>/dev/null || true)"
  PROBE_SUMMARY="$(printf '%s' "$PROBE" | tr ' ' '\n' | grep -c '^allotmentBaseUnits=' || true)"
  if [[ "$PROBE_SUMMARY" != "1" ]]; then
    fail "the faucet probe did not run inside the kernel container (is the image rebuilt at this KERNEL_REF?): ${PROBE:0:300}"
  else
    ALLOT_COINS="$(printf '%s' "$PROBE" | sed -n 's/.*allotmentCoins=\([0-9][0-9]*\).*/\1/p' | head -1)"
    ALLOT_UNITS="$(printf '%s' "$PROBE" | sed -n 's/.*allotmentBaseUnits=\([0-9][0-9]*\).*/\1/p' | head -1)"
    ALLOT_DEC="$(printf '%s' "$PROBE" | sed -n 's/.*defaultDecimals=\([0-9][0-9]*\).*/\1/p' | head -1)"
    if [[ "$ALLOT_COINS" == "1000" && "$ALLOT_UNITS" == "1000000000" && "$ALLOT_DEC" == "6" ]]; then
      ok "one faucet mint is exactly ${ALLOT_COINS} whole coins = ${ALLOT_UNITS} base units at ${ALLOT_DEC} decimals"
    else
      fail "the faucet allotment is coins=${ALLOT_COINS:-none} baseUnits=${ALLOT_UNITS:-none} decimals=${ALLOT_DEC:-none},
            expected 1000 / 1000000000 / 6 (kernel PR #63) — KERNEL_REF may be pinned before the whole-coin line"
    fi

    WBTC_COLOUR="$(printf '%s' "$PROBE" | grep 'name=WBTC ' | sed -n 's/.*colour=\([0-9a-f]\{64\}\).*/\1/p' | head -1)"
    WETH_COLOUR="$(printf '%s' "$PROBE" | grep 'name=WETH ' | sed -n 's/.*colour=\([0-9a-f]\{64\}\).*/\1/p' | head -1)"
    if [[ -z "$WBTC_COLOUR" || -z "$WETH_COLOUR" ]]; then
      fail "the faucet probe did not report both preset colours: ${PROBE:0:300}"
    else
      ok "faucet presets registered at 6 decimals: WBTC ${WBTC_COLOUR:0:16}…, WETH ${WETH_COLOUR:0:16}…"
      PP="$(curl -fsS --max-time 15 "$API/v1/prices?tokens=${WBTC_COLOUR},${WETH_COLOUR}" 2>/dev/null || true)"
      if [[ -z "$PP" ]]; then
        fail "GET /v1/prices for the two faucet presets did not answer"
      else
        # One row per preset: <name> <colour> <asset id> <the literal the whole-coin line names>.
        # Read field by field rather than `set --`, which would clobber this script's own "$@".
        #
        # THE SEEDED LITERAL IS ONLY AN EXPECTATION WHILE THE PRICE IS SEEDED (00014 FR-005).
        # `0.077387` and `0.00239328` are 000-init.sql's 2026-09-02 captures, and the `prices`
        # profile exists to replace them: after one CoinGecko refresh WBTC reads whatever
        # bitcoin costs today, `source` moves from `seed` to `feed`, and comparing against the
        # literal would fail a stack that is working exactly as designed. So the literal is
        # asserted for `seed`/`fixed` rows and REPORTED for `feed`/`manual` ones.
        #
        # The assertion that holds either way — and the one that actually encodes the whole-coin
        # line — is the EXACTNESS rule directly above it: per-base-unit == coin / 10^decimals,
        # as decimal strings. That is checked on whichever value is live, and
        # scripts/verify-prices.sh checks it again on FED values with the same helper.
        while read -r P_NAME P_COLOUR P_ASSET P_WANT; do
          [[ -n "$P_NAME" ]] || continue
          P_TOKEN_ROW="$(printf '%s' "$PP" | tr '{' '\n' | grep -E "\"token_color\":\"${P_COLOUR}\"" | head -1)"
          P_ASSET_ROW="$(printf '%s' "$PP" | tr '{' '\n' | grep "\"asset_id\":\"${P_ASSET}\"" | grep -v '"token_color"' | head -1)"
          if [[ -z "$P_TOKEN_ROW" ]]; then
            fail "GET /v1/prices has no tokens[] row for ${P_NAME} (${P_COLOUR:0:16}…): ${PP:0:300}"
            continue
          fi
          if [[ -z "$P_ASSET_ROW" ]]; then
            fail "GET /v1/prices has no assets[] row for ${P_ASSET} — ${P_NAME} is not priced by the built-in NAME map"
            continue
          fi
          P_DEC="$(printf '%s' "$P_TOKEN_ROW" | sed -n 's/.*"decimals":\([0-9][0-9]*\).*/\1/p' | head -1)"
          P_UNIT="$(printf '%s' "$P_TOKEN_ROW" | sed -n 's/.*"price_usd":"\([0-9.]*\)".*/\1/p' | head -1)"
          P_COIN="$(printf '%s' "$P_ASSET_ROW" | sed -n 's/.*"price_usd":"\([0-9.]*\)".*/\1/p' | head -1)"
          P_SOURCE="$(printf '%s' "$P_TOKEN_ROW" | sed -n 's/.*"source":"\([a-z-]*\)".*/\1/p' | head -1)"
          if [[ "$P_DEC" != "6" ]]; then
            fail "${P_NAME} is registered at ${P_DEC:-none} decimals, expected exactly 6"
            continue
          fi
          if [[ -z "$P_UNIT" || -z "$P_COIN" ]]; then
            fail "could not read ${P_NAME}'s per-base-unit / coin price_usd: ${P_TOKEN_ROW:0:200}"
            continue
          fi
          P_EXPECTED="$(decimal_shift_left "$P_COIN" "$P_DEC")"
          if [[ "$P_UNIT" != "$P_EXPECTED" ]]; then
            fail "${P_NAME}'s per-base-unit price is ${P_UNIT}, expected ${P_COIN} / 10^${P_DEC} = ${P_EXPECTED} exactly
                  (source=${P_SOURCE:-none})"
            continue
          fi
          case "$P_SOURCE" in
            feed|manual)
              # A REFRESH HAPPENED (or an operator set the row). The exactness rule above is
              # what the whole-coin line means here, and it passed; the seeded literal is
              # printed as context, never asserted, because a live price is supposed to move.
              ok "${P_NAME} per base unit is ${P_UNIT} == ${P_COIN} / 10^${P_DEC}, exactly (source=${P_SOURCE}; the 2026-09-02 seed was ${P_WANT})" ;;
            seed|fixed|"")
              if [[ "$P_UNIT" == "$P_WANT" ]]; then
                ok "${P_NAME} per base unit is ${P_UNIT} == ${P_COIN} / 10^${P_DEC}, exactly (source=${P_SOURCE:-seed})"
              else
                fail "${P_NAME} prices at ${P_UNIT} per base unit, but the whole-coin line specifies ${P_WANT}
                      (seeded ${P_ASSET} coin price in 000-init.sql is ${P_COIN}, source=${P_SOURCE:-seed}) — the seed moved"
              fi ;;
            *)
              # `fallback` (or `demo-fallback`) means the colour is not priced from an asset at
              # all — the deterministic colour-hash demo price. It is NOT a market price and
              # the sponsorship gate treats it as unpriced, so it must not pass here.
              fail "${P_NAME}'s price has source='${P_SOURCE}' — expected a real price (seed/feed/manual/fixed).
                    'fallback' is the colour-derived demo value and means this preset is not mapped to ${P_ASSET}." ;;
          esac
        done <<EOF
WBTC ${WBTC_COLOUR} bitcoin 0.077387
WETH ${WETH_COLOUR} ethereum 0.00239328
EOF
      fi
    fi
  fi
fi

# ── ZK assets ────────────────────────────────────────────────────────────────
echo
log "kernel: zk assets"
# A REAL asset, not the bare `/keys/` prefix. `/keys/*` 404s on anything it cannot resolve to
# a file, and an unmounted route 404s too — so probing `/keys/` proves nothing at all. Naming
# a file that the image's compact stage actually produced turns this into an end-to-end check
# of build -> image -> served bytes, which is what the browser prover depends on.
for asset in "/keys/mint_shielded.prover" "/keys/mint_shielded.verifier" "/zkir/mint_shielded.bzkir"; do
  read -r code size <<<"$(curl -s --max-time 20 -o /dev/null -w '%{http_code} %{size_download}' "${API}${asset}" 2>/dev/null || echo '000 0')"
  if [[ "$code" == "200" ]] && (( size > 0 )); then
    ok "${asset} served (${size} bytes)"
  else
    fail "${asset} not served (HTTP ${code}, ${size} bytes) — the browser prover fetches from here"
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
