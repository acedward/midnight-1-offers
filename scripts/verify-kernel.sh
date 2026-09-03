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
#   prices          GET /v1/prices?tokens=<NIGHT colour> answers a SEEDED price (source
#                   feed|seed|manual, never fallback) for `midnight-3` — kernel PR #54's
#                   reference-price table, seeded offline by 000-init.sql with no CoinGecko
#                   network dependency. The standalone price-feed REFRESH service is not part
#                   of this stack (.env.example); this is what proves the seed alone is enough.
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

# The sNight row — a DIFFERENT one-shot (images/shielded-night/entrypoint-token-name.sh), run
# by up.sh only when BOTH `offerfiles` AND `shielded-night` are up (the profile itself declares
# no dependency on a kernel — spec FR-002/FR-015). Reported, not hard-failed, when
# shielded-night is not part of this bring-up: this script's job is the offerfiles profile,
# and a stack legitimately brought up as `--with offerfiles` alone has nothing to check here.
if service_present shielded-night; then
  if [[ -n "$KNOWN" ]] && printf '%s' "$KNOWN" | grep -qi '"name":"snight"'; then
    SNIGHT_ROW="$(printf '%s' "$KNOWN" | tr '{' '\n' | grep -i '"name":"snight"' | head -1)"
    if printf '%s' "$SNIGHT_ROW" | grep -Eq '"decimals":[0-9]+' && printf '%s' "$SNIGHT_ROW" | grep -q '"asset_id":"midnight-3"'; then
      ok "sNight is registered PRICED: $(printf '%s' "$SNIGHT_ROW" | grep -oE '"decimals":[0-9]+|"asset_id":"[^"]*"' | tr '\n' ' ')"
    else
      fail "sNight is named but not priced (no decimals/asset_id): ${SNIGHT_ROW:0:200}"
    fi
  else
    fail "shielded-night is up but /v1/known-tokens names no sNight row — the shielded-night-token-name one-shot did not run or failed"
  fi
else
  info "shielded-night profile not up on this bring-up — nothing to check for the sNight row"
fi

# ── reference prices (kernel PR #54) ──────────────────────────────────────────
# GET /v1/prices?tokens= is REQUIRED and bounded (Q-11 of the kernel's own plan), so this asks
# for exactly NIGHT's own colour (0x00…00, seeded unconditionally) rather than the unfiltered
# form main no longer serves. A `source` of `feed` or `seed` (never `fallback`) is what "the
# seed is enough, no live CoinGecko feed needed" actually means — `fallback` is the $1
# unknown-token path and would mean the seed migration did not run.
echo
log "kernel: prices"
NIGHT_COLOR="0000000000000000000000000000000000000000000000000000000000000000"
PRICES="$(curl -fsS --max-time 10 "$API/v1/prices?tokens=${NIGHT_COLOR}" 2>/dev/null || true)"
if [[ -z "$PRICES" ]]; then
  fail "GET /v1/prices?tokens=<NIGHT> did not answer"
elif printf '%s' "$PRICES" | grep -q '"asset_id":"midnight-3"' \
     && printf '%s' "$PRICES" | grep -Eq '"source":"(feed|seed|manual)"'; then
  ok "GET /v1/prices reports a real (non-fallback) price for midnight-3 (NIGHT): ${PRICES:0:160}"
else
  fail "GET /v1/prices did not report a seeded/fed price for NIGHT (midnight-3): ${PRICES:0:300}"
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
