#!/usr/bin/env bash
#
# Assertions for the `poster` profile — the `poster` section of ./verify.sh.
#
#   ./scripts/verify-poster.sh
#
# WHAT IT PROVES, and why each check is here rather than assumed:
#
#   health          GET /health on the PUBLISHED port answers 200 with a permitted `state`.
#                   That alone proves very little, and deliberately so: the poster answers
#                   200 while it is `starting` AND while it is `degraded` (no dust yet),
#                   because restarting a poster whose operator has not sent it NIGHT would
#                   not produce NIGHT. So a green healthcheck is NOT evidence that anything
#                   was ever posted — which is exactly why the next check exists.
#   it is WORKING   within POSTER_VERIFY_BUDGET_S, `mints >= 2` and `liveOffers >= 2`. Two,
#                   not one: one mint could be a lucky first tick, two means the loop is a
#                   loop. Budget exhaustion is a FAILURE naming the last state and lastError,
#                   never a skip.
#   the exact coin  THE strongest claim this profile makes, and the reason the poster builds
#                   its own facade with a pinned coin selector at all: every offer spends
#                   exactly ONE coin, WHOLE. Asserted from OUTSIDE the poster by comparing
#                   two independent records — the journal's own `nullifier` for that coin,
#                   and the kernel's `computed.inputNullifiers` for the offer built from it.
#                   One entry, equal. A poster that leaked a second input, or spent a coin it
#                   did not record, fails here.
#   sponsored       GET /v1/quote for that offer's ACTUAL legs, with the offer's own want
#                   amount as `to_amount`, answers `sponsored: true`. The `to_amount` is not
#                   optional: without it the kernel quotes its own suggested amount, which
#                   lands on the sponsorship threshold BY CONSTRUCTION and would make this a
#                   check that cannot fail. With it, this is the batcher's real question —
#                   "would I pay this offer's Celestia fee?" — asked of the offer as posted.
#   size range      only when a range is configured: the last two mints differ in size.
#   a real take     e2e-taker settles ONE poster offer on chain and is credited EXACTLY the
#                   give amount, having paid EXACTLY the want amount. Offers that are listed
#                   but not settle-able would satisfy everything above.
#
# WHAT IT DELIBERATELY DOES NOT PROVE. Sponsorship END TO END — that the batcher actually
# paid — is the batcher's own lane; this asserts the kernel's verdict on the offer, which is
# the input to that decision. And it does not assert a specific number of offers on the book:
# a poster running beside a taker legitimately oscillates.
#
# ── THE ONE SIDE EFFECT THIS SCRIPT HAS ─────────────────────────────────────
# The take CONSUMES one poster offer, and funds `e2e-taker` with NIGHT from genesis and with
# the demanded token from the faucet circuit to do it. That is a real settlement on a
# throwaway devnet, and it is the point. Set POSTER_VERIFY_SKIP_TAKE=true to skip it (it
# costs two provings, ~2-4 min); the skip is printed with its reason, never silent.
#
# ── bash 3.2 AND `pipefail` ─────────────────────────────────────────────────
# Every count/extract helper below ends in `|| true`. Under `set -euo pipefail` a `grep` or
# `sed -n` that legitimately matches NOTHING exits 1, `pipefail` makes that the pipeline's
# status, and `set -e` then kills the script from inside `$( )` — silently, at exactly the
# empty state the check exists to handle. That cost one gate run in 00011 phase B; it is a
# design rule here rather than a lesson to relearn.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"

require_docker
load_env
# Every fragment, not just poster: `dc exec` must resolve the service, and naming one profile
# makes compose call every other profile's containers orphans on each invocation.
use_all_profiles

BIND="${HOST_ADDR:-127.0.0.1}"
POSTER="http://${BIND}:${POSTER_HEALTH_HOST_PORT:-19977}"
KERNEL="http://${BIND}:${KERNEL_HOST_PORT:-9999}"

# How long the poster may take to reach two mints and two live offers. The FIRST mint is
# wallet sync + DUST registration + the dust wait + a contract join + ~30 s of proving, and
# the second is one POST_INTERVAL_MS later — so this is minutes, not seconds.
BUDGET_S="${POSTER_VERIFY_BUDGET_S:-420}"
WANT_MINTS="${POSTER_VERIFY_MIN_MINTS:-2}"
WANT_LIVE="${POSTER_VERIFY_MIN_LIVE_OFFERS:-2}"

# The take's two wallets. e2e-taker starts empty at genesis (measured), so the driver funds it
# — NIGHT from the faucet wallet, and the demanded token from the faucet CIRCUIT, because
# nothing on this stack holds a faucet preset until something mints one.
TAKE_TAKER_SEED="${POSTER_TAKE_TAKER_SEED:-${TAKER_SEED:-0000000000000000000000000000000000000000000000000000000000000032}}"
TAKE_FUNDER_SEED="${POSTER_TAKE_FUNDER_SEED:-${MIDNIGHT_GENESIS_SEED:-0000000000000000000000000000000000000000000000000000000000000001}}"
# The poster's two legs as NAMES. Blank in .env means the poster's own code defaults, which
# are WBTC and WETH — so the same blank-means-default rule applies on this side.
GIVE_NAME="${OFFER_POSTER_GIVE_TOKEN:-}"
[[ -n "$GIVE_NAME" ]] || GIVE_NAME="WBTC"
WANT_NAME="${OFFER_POSTER_WANT_TOKEN:-}"
[[ -n "$WANT_NAME" ]] || WANT_NAME="WETH"

FAILURES=0
fail() { err "$*"; FAILURES=$(( FAILURES + 1 )); }

# ── JSON scraping, without jq ────────────────────────────────────────────────
# These verify scripts take no dependency a stock macOS box lacks, so anything nested is read
# from INSIDE a container with `bun -e` (below) and anything flat is scraped here.
#
# `|| true` on both, for the reason in the header.
json_str() {  # json_str <body> <key>
  printf '%s' "$1" \
    | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | sed "s/.*:[[:space:]]*\"//; s/\"\$//" | head -1 || true
}
json_num() {  # json_num <body> <key>
  printf '%s' "$1" \
    | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*-?[0-9]+" \
    | grep -oE -- '-?[0-9]+$' | head -1 || true
}
json_bool() {  # json_bool <body> <key> — "true", "false", or empty when absent.
  # Whitespace-tolerant rather than an exact-substring match on `"key":true`: the kernel's
  # serialiser emits no spaces today, and a check that silently starts failing if that ever
  # changes is a worse assertion than one that reads the value.
  printf '%s' "$1" \
    | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*(true|false)" \
    | grep -oE '(true|false)$' | head -1 || true
}

# ── the health surface, on the PUBLISHED port ────────────────────────────────
echo
log "poster: endpoints"
info "health  ${POSTER}/health   (also /metrics and /journal — all read-only, no auth)"
info "kernel  ${KERNEL}"

echo
log "poster: health"
HEALTH_FILE="$(mktemp)"
trap 'rm -f "$HEALTH_FILE"' EXIT
HEALTH_CODE="$(curl -sS --max-time 15 -o "$HEALTH_FILE" -w '%{http_code}' "$POSTER/health" 2>/dev/null || true)"
HEALTH_BODY="$(tr -d '\n' < "$HEALTH_FILE" 2>/dev/null || true)"
if [[ "$HEALTH_CODE" != "200" ]]; then
  fail "GET ${POSTER}/health answered ${HEALTH_CODE:-nothing}: ${HEALTH_BODY:-empty}"
  info "503 means HEALTH_STALE_TICKS consecutive FAILED ticks — read the reason with:"
  dim  "docker compose logs --tail=80 offer-poster"
  exit 1
fi
STATE="$(json_str "$HEALTH_BODY" state)"
case "${STATE:-}" in
  starting|ok|degraded)
    ok "GET ${POSTER}/health answers 200 with state '${STATE}'"
    ;;
  unhealthy|stopping)
    fail "the poster reports state '${STATE}' — it is not servicing ticks"
    ;;
  *)
    fail "GET /health answered 200 but carries no readable state: ${HEALTH_BODY:0:200}"
    ;;
esac
if [[ "${STATE:-}" == "degraded" ]]; then
  info "'degraded' is a 200 BY DESIGN — it usually means insufficient_dust, i.e. the wallet"
  info "has no NIGHT. poster-provision is what funds it; check that one-shot's exit."
fi

# ── it is actually WORKING ───────────────────────────────────────────────────
echo
log "poster: mints and live offers (budget ${BUDGET_S}s)"
START=$SECONDS
DEADLINE=$(( SECONDS + BUDGET_S ))
MINTS=""; LIVE=""; LAST_ERROR=""
while :; do
  HEALTH_BODY="$(curl -sS --max-time 15 "$POSTER/health" 2>/dev/null | tr -d '\n' || true)"
  MINTS="$(json_num "$HEALTH_BODY" mints)"
  LIVE="$(json_num "$HEALTH_BODY" liveOffers)"
  STATE="$(json_str "$HEALTH_BODY" state)"
  LAST_ERROR="$(json_str "$HEALTH_BODY" lastError)"
  if [[ -n "${MINTS:-}" && -n "${LIVE:-}" ]] \
     && (( MINTS >= WANT_MINTS )) && (( LIVE >= WANT_LIVE )); then
    break
  fi
  (( SECONDS < DEADLINE )) || break
  sleep 10
done
ELAPSED=$(( SECONDS - START ))
if [[ -n "${MINTS:-}" && -n "${LIVE:-}" ]] && (( MINTS >= WANT_MINTS )) && (( LIVE >= WANT_LIVE )); then
  ok "the poster has minted ${MINTS} coin(s) and holds ${LIVE} live offer(s) after ${ELAPSED}s"
  info "state='${STATE:-?}'  reoffers=$(json_num "$HEALTH_BODY" reoffers)  ticks=$(json_num "$HEALTH_BODY" ticks)"
else
  fail "after ${ELAPSED}s the poster reports mints=${MINTS:-unreadable} liveOffers=${LIVE:-unreadable}, wanted >= ${WANT_MINTS} / >= ${WANT_LIVE}"
  info "last state '${STATE:-?}', lastError '${LAST_ERROR:-none}'"
  info "the poster's own log names the cause:"
  dim  "docker compose logs --tail=120 offer-poster"
  exit 1
fi

# ── the exact-coin guarantee ─────────────────────────────────────────────────
# Read from INSIDE the poster container, because the comparison is between two NESTED
# documents (the journal's coins[<nonce>].offers[] and the kernel's computed.inputNullifiers)
# and this host has neither jq nor bun. The probe never exits non-zero: a soft failure prints
# `fetch=…` and the assertions below report it.
#
# A QUOTED heredoc, so nothing here is expanded by this shell.
read -r -d '' JOURNAL_PROBE_JS <<'PROBE_JS' || true
const api = (process.env.ZSWAP_API || "http://kernel:9999").replace(/\/$/, "");
const out = [];
const r = await fetch("http://127.0.0.1:9977/journal", { signal: AbortSignal.timeout(10000) }).catch(() => null);
if (!r || !r.ok) { console.log("fetch=fail"); process.exit(0); }
const j = await r.json().catch(() => null);
if (!j || typeof j !== "object") { console.log("fetch=unparseable"); process.exit(0); }
out.push("fetch=ok");
out.push("contractAddress=" + (j.contractAddress ?? "?"));
const coins = j.coins && typeof j.coins === "object" ? j.coins : {};
let total = 0;
let best = null;   // newest LIVE offer
let newest = null; // newest offer of any status
for (const [nonce, coin] of Object.entries(coins)) {
  for (const offer of coin.offers ?? []) {
    total += 1;
    if (newest === null || String(offer.postedAt) > String(newest.offer.postedAt)) newest = { nonce, coin, offer };
    if (offer.status === "live" && (best === null || String(offer.postedAt) > String(best.offer.postedAt))) {
      best = { nonce, coin, offer };
    }
  }
}
out.push("journalCoins=" + Object.keys(coins).length);
out.push("journalOffers=" + total);
const pick = best ?? newest;
if (pick === null) { console.log(out.join(String.fromCharCode(10))); process.exit(0); }
out.push("picked=" + (best === null ? "newest" : "live"));
out.push("nonce=" + pick.nonce);
out.push("offerId=" + pick.offer.offerId);
out.push("journalStatus=" + pick.offer.status);
out.push("coinNullifier=" + (pick.coin.nullifier ?? "none"));
out.push("coinType=" + (pick.coin.type ?? "?"));
out.push("coinValue=" + (pick.coin.value ?? "?"));
out.push("coinState=" + (pick.coin.state ?? "?"));
out.push("journalQuoteSponsored=" + ((pick.offer.quote ?? {}).sponsored === true));
const k = await fetch(api + "/v1/offers/" + pick.offer.offerId, { signal: AbortSignal.timeout(15000) }).catch(() => null);
if (!k || !k.ok) { out.push("kernel=fail:" + (k ? k.status : "unreachable")); console.log(out.join(String.fromCharCode(10))); process.exit(0); }
const o = await k.json().catch(() => null);
if (!o || !o.computed) { out.push("kernel=unparseable"); console.log(out.join(String.fromCharCode(10))); process.exit(0); }
out.push("kernel=ok");
out.push("kernelStatus=" + o.computed.status);
const nulls = Array.isArray(o.computed.inputNullifiers) ? o.computed.inputNullifiers : [];
out.push("kernelNullifierCount=" + nulls.length);
out.push("kernelNullifier=" + (nulls[0] ?? "none"));
const gives = o.computed.gives ?? [];
const wants = o.computed.wants ?? [];
out.push("giveToken=" + (gives[0] ? gives[0].token : "?"));
out.push("giveAmount=" + (gives[0] ? gives[0].amount : "?"));
out.push("giveLegs=" + gives.length);
out.push("wantToken=" + (wants[0] ? wants[0].token : "?"));
out.push("wantAmount=" + (wants[0] ? wants[0].amount : "?"));
out.push("wantLegs=" + wants.length);
console.log(out.join(String.fromCharCode(10)));
PROBE_JS

echo
log "poster: the exact-coin guarantee"
# `|| true`: a poster that is down makes `dc exec` fail, and this must report that rather
# than let `set -e` end the run.
FIELDS="$(dc exec -T offer-poster bun -e "$JOURNAL_PROBE_JS" 2>/dev/null || true)"
field() {  # field <key> — one flat key=value line from the probe
  printf '%s\n' "$FIELDS" | sed -n "s/^$1=//p" | head -1 || true
}

if [[ "$FIELDS" != *"fetch=ok"* ]]; then
  fail "could not read the poster's journal (${FIELDS:-no output})"
  exit 1
fi
J_OFFERS="$(field journalOffers)"
info "the journal records $(field journalCoins) coin(s) and ${J_OFFERS:-0} offer(s), contract $(field contractAddress)"
OFFER_ID="$(field offerId)"
if [[ -z "${OFFER_ID:-}" ]]; then
  fail "the journal records no offer at all, yet /health reported ${MINTS} mint(s)"
  exit 1
fi
info "checking offer ${OFFER_ID:0:16}… (the newest $(field picked) one), minted on coin nonce $(field nonce)"

COIN_NULL="$(field coinNullifier)"
KERNEL_STATUS="$(field kernelStatus)"
KERNEL_NULL="$(field kernelNullifier)"
KERNEL_NULL_COUNT="$(field kernelNullifierCount)"

if [[ "$FIELDS" != *"kernel=ok"* ]]; then
  fail "the kernel could not answer for that offer ($(field kernel))"
elif [[ "$KERNEL_STATUS" == "live" ]]; then
  ok "the kernel reports offer ${OFFER_ID:0:16}… LIVE"
else
  fail "the kernel reports offer ${OFFER_ID:0:16}… as '${KERNEL_STATUS:-unreadable}', expected live"
fi

if [[ "${KERNEL_NULL_COUNT:-0}" == "1" ]]; then
  ok "the offer spends exactly ONE input (no change output — it spends its coin whole)"
else
  fail "the offer spends ${KERNEL_NULL_COUNT:-unreadable} inputs; the exact-coin guarantee is one"
fi
if [[ -n "${COIN_NULL:-}" && "$COIN_NULL" != "none" && "$COIN_NULL" == "$KERNEL_NULL" ]]; then
  ok "…and that input is EXACTLY the journal coin's nullifier (${COIN_NULL:0:16}…)"
else
  fail "the journal's coin nullifier and the kernel's input nullifier differ"
  info "journal: ${COIN_NULL:-none}"
  info "kernel : ${KERNEL_NULL:-none}"
fi
if [[ "$(field giveLegs)" == "1" && "$(field wantLegs)" == "1" ]]; then
  ok "the offer has exactly one give leg and one want leg"
else
  fail "the offer has $(field giveLegs) give leg(s) and $(field wantLegs) want leg(s), expected 1 and 1"
fi
if [[ "$(field coinValue)" == "$(field giveAmount)" ]]; then
  ok "the give amount is the coin's whole value ($(field giveAmount) base units)"
else
  fail "the offer gives $(field giveAmount) of a coin worth $(field coinValue) — that is not a whole spend"
fi

# ── the offer as posted is SPONSORABLE ───────────────────────────────────────
echo
log "poster: sponsorship"
GIVE_TOKEN="$(field giveToken)"
GIVE_AMOUNT="$(field giveAmount)"
WANT_TOKEN="$(field wantToken)"
WANT_AMOUNT="$(field wantAmount)"
if [[ "$GIVE_TOKEN" =~ ^[0-9a-f]{64}$ && "$WANT_TOKEN" =~ ^[0-9a-f]{64}$ ]]; then
  QUOTE="$(curl -fsS --max-time 20 \
    "${KERNEL}/v1/quote?from_token=${GIVE_TOKEN}&to_token=${WANT_TOKEN}&from_amount=${GIVE_AMOUNT}&to_amount=${WANT_AMOUNT}" \
    2>/dev/null | tr -d '\n' || true)"
  SPONSORED="$(json_bool "$QUOTE" sponsored)"
  if [[ -z "$QUOTE" ]]; then
    fail "GET /v1/quote for the poster's own legs did not answer"
  elif [[ "$SPONSORED" == "true" ]]; then
    ok "GET /v1/quote says the offer as posted is SPONSORED (the batcher pays its Celestia fee)"
    info "give ${GIVE_AMOUNT} of ${GIVE_TOKEN:0:12}… → want ${WANT_AMOUNT} of ${WANT_TOKEN:0:12}…"
    info "suggested_to_amount=$(json_str "$QUOTE" suggested_to_amount)  from_source=$(json_str "$QUOTE" from_source)  to_source=$(json_str "$QUOTE" to_source)"
  else
    fail "GET /v1/quote says sponsored=${SPONSORED:-unreadable}: ${QUOTE:0:300}"
    info "the want leg is sized from this same quote every tick, so a false here means the"
    info "prices moved between posting and now, or a leg is unpriced (from_source/to_source"
    info "would read demo-fallback — the poster registers both names at startup for this)."
  fi
else
  fail "could not read the offer's two colours from the kernel"
fi

# ── a configured size range really varies the size ───────────────────────────
if [[ -n "${OFFER_POSTER_GIVE_MIN:-}" || -n "${OFFER_POSTER_GIVE_MAX:-}" ]]; then
  echo
  log "poster: the size range"
  read -r -d '' SIZES_PROBE_JS <<'SIZES_JS' || true
const r = await fetch("http://127.0.0.1:9977/journal", { signal: AbortSignal.timeout(10000) }).catch(() => null);
if (!r || !r.ok) { console.log("sizes=fail"); process.exit(0); }
const j = await r.json().catch(() => null);
if (!j) { console.log("sizes=unparseable"); process.exit(0); }
const coins = Object.values(j.coins ?? {});
coins.sort((a, b) => String(a.mintedAt).localeCompare(String(b.mintedAt)));
console.log("sizes=" + coins.slice(-2).map((c) => String(c.value)).join(","));
SIZES_JS
  SIZES="$(dc exec -T offer-poster bun -e "$SIZES_PROBE_JS" 2>/dev/null | sed -n 's/^sizes=//p' | head -1 || true)"
  FIRST_SIZE="${SIZES%%,*}"
  LAST_SIZE="${SIZES##*,}"
  if [[ -z "${SIZES:-}" || "$SIZES" == "fail" || "$FIRST_SIZE" == "$SIZES" ]]; then
    fail "could not read two mint sizes from the journal (got '${SIZES:-nothing}')"
  elif [[ "$FIRST_SIZE" != "$LAST_SIZE" ]]; then
    ok "the last two mints differ in size (${FIRST_SIZE} then ${LAST_SIZE} base units)"
  else
    fail "a range is configured but the last two mints are both ${FIRST_SIZE} base units"
    info "a log-uniform draw CAN repeat, but with OFFER_POSTER_SIZE_SEED unset it is unlikely;"
    info "check that OFFER_POSTER_GIVE_AMOUNT is blank — a fixed size wins and the poster says so."
  fi
else
  info "no OFFER_POSTER_GIVE_MIN/_GIVE_MAX configured — every mint is the same size, so the"
  info "spread assertion does not apply (this is the shipped default)"
fi

# ── somebody else settles one of them ────────────────────────────────────────
echo
log "poster: a taker settles one poster offer"
if [[ "${POSTER_VERIFY_SKIP_TAKE:-false}" == "true" || "${POSTER_VERIFY_SKIP_TAKE:-false}" == "1" ]]; then
  warn "SKIP (POSTER_VERIFY_SKIP_TAKE=${POSTER_VERIFY_SKIP_TAKE}) — the offers above were"
  info "asserted LIVE and sponsorable, but nothing proved one can actually be settled."
else
  info "e2e-taker (…${TAKE_TAKER_SEED: -4}) funded with NIGHT from …${TAKE_FUNDER_SEED: -4}, then"
  info "it MINTS the demanded ${WANT_NAME} itself — nothing on this stack holds a faucet preset"
  info "until something mints one. Two provings; this is the long one."
  TAKE_OUT="$(mktemp)"
  TAKE_RC=0
  dc run --rm --no-deps -T \
    -v "${REPO_ROOT}/scripts/driver:/app/stack-driver:ro" \
    -e "ZSWAP_API=http://kernel:9999" \
    -e "TAKER_SEED=${TAKE_TAKER_SEED}" \
    -e "FUNDER_SEED=${TAKE_FUNDER_SEED}" \
    -e "GIVE_TOKEN_NAME=${GIVE_NAME}" \
    -e "WANT_TOKEN_NAME=${WANT_NAME}" \
    --entrypoint bun kernel run stack-driver/take-poster-offer.ts >"$TAKE_OUT" 2>&1 || TAKE_RC=$?
  sed 's/^/      /' "$TAKE_OUT" >&2
  RESULT="$(grep -m1 '^POSTER_TAKE_RESULT ' "$TAKE_OUT" || true)"
  rm -f "$TAKE_OUT"
  if (( TAKE_RC == 0 )) && [[ -n "$RESULT" ]]; then
    take_field() { printf '%s' "$RESULT" | sed -n "s/.* $1=\\([^ ]*\\).*/\\1/p" | head -1 || true; }
    ok "offer $(take_field offerId | cut -c1-16)… is $(take_field status) on chain"
    ok "the taker was credited EXACTLY $(take_field giveAmount) (${GIVE_NAME}: $(take_field giveBefore) → $(take_field giveAfter))"
    ok "…and paid EXACTLY $(take_field wantAmount) (${WANT_NAME}: $(take_field wantBefore) → $(take_field wantAfter))"
  else
    fail "the take failed — a poster offer was listed but could not be settled (see above)"
  fi
fi

echo
if (( FAILURES == 0 )); then
  ok "poster: all assertions passed"
  exit 0
fi
err "poster: ${FAILURES} assertion(s) failed"
exit 1
