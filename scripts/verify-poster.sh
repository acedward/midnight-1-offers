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
#   the inventory   the pre-mint landed: `/health`'s `freeCoins` plus the coins already
#                   adopted account for POSTER_PREMINT_COUNT. The poster does not mint at this
#                   pin — `poster-inventory` does, before it starts — so a poster with an empty
#                   wallet is `degraded: insufficient_inventory` for ever while looking healthy.
#   it is WORKING   within POSTER_VERIFY_BUDGET_S, `inventoryAdoptions + reoffers >= 2` and
#                   `liveOffers >= 2`. Two, not one: one could be a lucky first tick, two means
#                   the loop is a loop. `mints` WAS the field here and is gone from /health at
#                   this pin, with the mint it counted (kernel #69); `inventoryAdoptions` counts
#                   ticks that adopted a prefunded coin and `reoffers` ticks that re-offered a
#                   released one — the two ways a tick can produce an offer now. Budget
#                   exhaustion is a FAILURE naming the last state and lastError, never a skip.
#                   `degraded: insufficient_inventory` is accepted ONLY after the budgeted count
#                   has been reached: before that it means the pre-mint did not land.
#   the exact coin  THE strongest claim this profile makes, and the reason the poster builds
#                   its own facade with a pinned coin selector at all: every offer spends
#                   exactly ONE coin, WHOLE. Asserted from OUTSIDE the poster by comparing
#                   two independent records — the journal's own `nullifier` for that coin,
#                   and the kernel's `computed.inputNullifiers` for the offer built from it.
#                   One entry, equal. A poster that leaked a second input, or spent a coin it
#                   did not record, fails here.
#                   The offer it picks is the NEWEST live one, which the kernel typically
#                   cannot serve yet: the journal says `live` at POST acceptance and the book
#                   answers 404 for another 5-20 s. So this check WAITS for the kernel — up to
#                   POSTER_PROBE_WAIT_S (90), polling every POSTER_PROBE_POLL_S (3) — exactly
#                   as the poster's own `phase=live` loop does, and reports the measured wait.
#                   If the budget runs out it emits ONE failure naming the offer, the wait and
#                   the last status, and SKIPS the assertions that would read empty fields
#                   rather than turning one cause into six failures (issue 00017).
#   sponsored       TWO readings, and only one of them is an assertion.
#                   ASSERTED: the poster's OWN quote snapshot for that offer (journal,
#                   `QuoteSnapshot.sponsored`) says it was sponsorable WHEN IT WAS BUILT. That
#                   is the poster's actual contract — size the want leg onto the sponsorship
#                   threshold — and it is a claim about the poster rather than about the clock.
#                   REPORTED: `GET /v1/quote` for the offer's ACTUAL legs, with its own want
#                   amount as `to_amount`, right now. `sponsored` is
#                   `to_amount <= suggested_to_amount`, and `suggested` is recomputed from
#                   today's prices — so a fixed want leg goes false on any price move. At this
#                   pin the book is BOUNDED (the poster cannot mint), so the newest live offer
#                   can be tens of minutes old and this WILL go false on a long-running stack.
#                   Measured on this phase's own gate; see the block for the numbers.
#   first offer     THE OLDEST LIVE OFFER, not the newest — the end of the journal every other
#     priced        check here ignores, and the end where issues/00023 lived. Zero
#                   `demo-fallback` lines and zero `market_rate=1` quote lines in the poster's
#                   WHOLE log; zero offers in the journal whose own quote snapshot names a
#                   fallback source or a market rate of exactly 1; the oldest LIVE offer
#                   re-quoted with its exact legs still priced from market data and still within
#                   a band of the kernel's own `sponsor_discount`; and `docker inspect` showing
#                   the poster's `StartedAt` later than the registrar's `FinishedAt`. See that
#                   block's own header for why every assertion above it passed on a stack whose
#                   first two offers were mispriced by eleven orders of magnitude.
#   size range      only when a range is configured: the last two adopted coins differ in size.
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
# The take CONSUMES one poster offer, and to do it this script funds `e2e-taker` — NIGHT from
# genesis (inside the driver) and the DEMANDED TOKEN through `issuer-fund` (here, before the
# driver runs). The second half is new at this pin: up to `KERNEL_REF=a608fa6…` the taker minted
# the demanded token itself from the faucet circuit, and kernel #69 deleted that circuit. That
# is a real settlement on a throwaway devnet, and it is the point. Set
# POSTER_VERIFY_SKIP_TAKE=true to skip it (it costs a mint plus two provings, ~3-5 min); the
# skip is printed with its reason, never silent.
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

# How long the poster may take to reach two produced offers and two live offers. The FIRST is
# wallet sync + DUST registration + the dust wait + ~30 s of proving, and the second is one
# POST_INTERVAL_MS later — so this is minutes, not seconds.
BUDGET_S="${POSTER_VERIFY_BUDGET_S:-420}"
# `POSTER_VERIFY_MIN_MINTS` is still accepted as the override name so an existing `.env` keeps
# working; what it now bounds is `inventoryAdoptions + reoffers`, because the poster no longer
# mints anything (kernel #69) and `/health` no longer carries a `mints` field at all.
WANT_POSTED="${POSTER_VERIFY_MIN_POSTED:-${POSTER_VERIFY_MIN_MINTS:-2}}"
WANT_LIVE="${POSTER_VERIFY_MIN_LIVE_OFFERS:-2}"
# What `poster-inventory` was asked to pre-mint. The wallet should hold this many coins of the
# give size, minus the ones ticks have already adopted.
PREMINT_COUNT="${POSTER_PREMINT_COUNT:-12}"

# ── how long the exact-coin probe may wait for the kernel (issue 00017) ──────
# The poster marks an offer `live` in its journal the moment its POST is ACCEPTED, but the
# kernel's book serves that offer only 5-20 s later — the poster's own follow-up loop is built
# around exactly this window (`phase=live attempt=1 status=not_found` at +5 s, `phase=verify
# result=ok` at +10 s, on every tick). A single un-retried `GET /v1/offers/<newest live>` is
# therefore a coin flip on the clock: the 2026-09-04 full e2e run landed 4 s after an
# acceptance and turned ONE cause into SIX failing assertions on empty fields.
#
#   POSTER_PROBE_WAIT_S   total budget for the wait, in seconds (default 90 — the measured
#                         window is 5-20 s, so this is ~4x the worst case seen)
#   POSTER_PROBE_POLL_S   seconds between polls (default 3)
#
# Set POSTER_PROBE_WAIT_S=1 to assert the exhaustion path itself (it must produce exactly ONE
# failing assertion naming the offer, the wait and the last status — never a cascade).
PROBE_WAIT_S="${POSTER_PROBE_WAIT_S:-90}"
PROBE_POLL_S="${POSTER_PROBE_POLL_S:-3}"

# The take's two wallets. e2e-taker starts empty at genesis (measured), so it is funded twice:
# NIGHT from the faucet wallet (inside the driver) and the DEMANDED TOKEN by `issuer-fund`
# below — since kernel #69 nothing on this stack can mint from the taker's own wallet.
TAKE_TAKER_SEED="${POSTER_TAKE_TAKER_SEED:-${TAKER_SEED:-0000000000000000000000000000000000000000000000000000000000000032}}"
TAKE_FUNDER_SEED="${POSTER_TAKE_FUNDER_SEED:-${MIDNIGHT_GENESIS_SEED:-0000000000000000000000000000000000000000000000000000000000000001}}"
# The poster's two legs as ISSUER TOKEN NAMES, with compose's own defaults. They are no longer
# faucet presets (WBTC/WETH); the ids are resolved from the issuer's registry below, exactly as
# the poster's entrypoint resolves them from the handoff.
# NO INLINE FALLBACK — `load_env` (scripts/lib/common.sh) is the single place these are
# defaulted, and compose/poster.yml carries the twin literal. See that block in common.sh.
GIVE_NAME="${OFFER_POSTER_GIVE_TOKEN}"
WANT_NAME="${OFFER_POSTER_WANT_TOKEN}"
# How much of the want token the taker is given before the take. It must cover the offer's want
# leg, which is QUOTED per tick and therefore not known until the offer is picked — so this is
# deliberately generous rather than exact, and the driver fails with the shortfall and the exact
# `issuer-fund` command if it ever is not enough. One whole TWETH against a want leg quoted from
# 0.01 TWBTC is roughly two orders of magnitude of headroom.
TAKE_FUND_AMOUNT="${POSTER_TAKE_FUND_AMOUNT:-1000000000000000000}"

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
  info "'degraded' is a 200 BY DESIGN. At this pin it means insufficient_inventory — the wallet"
  info "holds no unjournaled coin worth exactly OFFER_POSTER_GIVE_AMOUNT. poster-inventory is"
  info "what pre-mints them and poster-provision is what funds the NIGHT; check both one-shots."
fi

# ── it is actually WORKING ───────────────────────────────────────────────────
#
# `mints` USED TO BE THE COUNTER HERE and does not exist at this pin: the poster never mints
# (kernel #69), and `deploy/scripts/lib/poster-health.ts` reports `inventoryAdoptions` (ticks
# that adopted a prefunded coin) and `reoffers` (ticks that re-offered a released one) instead.
# Their SUM is what "this loop produced an offer" means now, and asserting the sum rather than
# either one is deliberate: a stack whose coins have all been posted and are coming back is
# working exactly as designed, and would score zero adoptions.
echo
log "poster: offers produced and live (budget ${BUDGET_S}s)"
START=$SECONDS
DEADLINE=$(( SECONDS + BUDGET_S ))
ADOPTIONS=""; REOFFERS=""; POSTED=""; LIVE=""; LAST_ERROR=""; FREE_COINS=""
while :; do
  HEALTH_BODY="$(curl -sS --max-time 15 "$POSTER/health" 2>/dev/null | tr -d '\n' || true)"
  ADOPTIONS="$(json_num "$HEALTH_BODY" inventoryAdoptions)"
  REOFFERS="$(json_num "$HEALTH_BODY" reoffers)"
  LIVE="$(json_num "$HEALTH_BODY" liveOffers)"
  FREE_COINS="$(json_num "$HEALTH_BODY" freeCoins)"
  STATE="$(json_str "$HEALTH_BODY" state)"
  LAST_ERROR="$(json_str "$HEALTH_BODY" lastError)"
  POSTED=""
  if [[ -n "${ADOPTIONS:-}" && -n "${REOFFERS:-}" ]]; then
    POSTED=$(( ADOPTIONS + REOFFERS ))
  fi
  if [[ -n "${POSTED:-}" && -n "${LIVE:-}" ]] \
     && (( POSTED >= WANT_POSTED )) && (( LIVE >= WANT_LIVE )); then
    break
  fi
  (( SECONDS < DEADLINE )) || break
  sleep 10
done
ELAPSED=$(( SECONDS - START ))
if [[ -n "${POSTED:-}" && -n "${LIVE:-}" ]] && (( POSTED >= WANT_POSTED )) && (( LIVE >= WANT_LIVE )); then
  ok "the poster has produced ${POSTED} offer(s) (${ADOPTIONS} adopted + ${REOFFERS} re-offered) and holds ${LIVE} live after ${ELAPSED}s"
  info "state='${STATE:-?}'  freeCoins=${FREE_COINS:-?}  ticks=$(json_num "$HEALTH_BODY" ticks)"
else
  fail "after ${ELAPSED}s the poster reports inventoryAdoptions=${ADOPTIONS:-unreadable} reoffers=${REOFFERS:-unreadable} liveOffers=${LIVE:-unreadable}, wanted (adoptions+reoffers) >= ${WANT_POSTED} / live >= ${WANT_LIVE}"
  info "last state '${STATE:-?}', lastError '${LAST_ERROR:-none}', freeCoins '${FREE_COINS:-?}'"
  if [[ "${LAST_ERROR:-}" == *insufficient_inventory* || "${STATE:-}" == "degraded" ]]; then
    info "insufficient_inventory BEFORE the budgeted count means the PRE-MINT did not land, not"
    info "that the book is exhausted. poster-inventory mints POSTER_PREMINT_COUNT coins of"
    info "exactly OFFER_POSTER_GIVE_AMOUNT; the poster adopts a coin by EXACT value, so a size"
    info "mismatch between those two variables looks precisely like this:"
    dim  "docker compose logs poster-inventory"
  fi
  info "the poster's own log names the cause:"
  dim  "docker compose logs --tail=120 offer-poster"
  exit 1
fi

# ── THE PRE-MINT LANDED, and in the right SHAPE ──────────────────────────────
#
# `freeCoins` is the number of give-colour coins the wallet could spend right now; every
# adoption moves one out of that pool and into an offer. So the pre-mint is accounted for by
# `freeCoins + inventoryAdoptions`, and it is checked as a FLOOR rather than an equality: a
# released coin that has come back is spendable again and legitimately raises `freeCoins`.
#
# It is NOT the same claim as "the poster is posting" above. A poster given ONE coin posts it,
# re-offers it for ever and satisfies every assertion in this section — while the book it is
# supposed to keep supplied never grows past one offer.
if [[ -n "${FREE_COINS:-}" && -n "${ADOPTIONS:-}" ]]; then
  ACCOUNTED=$(( FREE_COINS + ADOPTIONS ))
  if (( ACCOUNTED >= PREMINT_COUNT )); then
    ok "the pre-minted inventory is accounted for: ${FREE_COINS} free + ${ADOPTIONS} adopted >= POSTER_PREMINT_COUNT ${PREMINT_COUNT}"
  else
    fail "only ${ACCOUNTED} coin(s) are accounted for (${FREE_COINS} free + ${ADOPTIONS} adopted),
          but poster-inventory was asked for ${PREMINT_COUNT}. The poster adopts a coin whose
          value EQUALS OFFER_POSTER_GIVE_AMOUNT, so the usual cause is those two variables
          disagreeing — compose reads them from the same one, so check for an override:"
    dim  "docker compose logs poster-inventory"
  fi
else
  warn "could not read freeCoins/inventoryAdoptions off /health — skipping the inventory count"
fi

# ── the exact-coin guarantee ─────────────────────────────────────────────────
# Read from INSIDE the poster container, because the comparison is between two NESTED
# documents (the journal's coins[<nonce>].offers[] and the kernel's computed.inputNullifiers)
# and this host has neither jq nor bun. The probe never exits non-zero: a soft failure prints
# `fetch=…` and the assertions below report it.
#
# THE WAIT (issue 00017). The probe does not ask the kernel once — it asks every
# POSTER_PROBE_POLL_S until the kernel SERVES the offer or POSTER_PROBE_WAIT_S runs out,
# because the poster's journal says `live` at POST acceptance and the kernel's book answers
# 404 for the next 5-20 s. That is the kernel's normal indexing latency, not a defect: the
# poster's own `phase=live` loop waits for exactly the same thing before it declares a tick
# good. Only a TERMINAL answer (`consumed`/`cancelled`/`expired` — the offer is over, waiting
# cannot help) ends the wait early, and then the probe tries the next-newest live entry ONCE
# with whatever budget is left, because a taker settling the newest offer mid-probe is a race
# to survive, not a failure to report.
#
# THE ZERO-WAIT ALTERNATIVE, and why it is not taken. Preferring an entry the POSTER has
# already verified against the kernel would need no wait at all — and no such field exists at
# kernel `c293ebd`: `/journal` serves `Journal.toJSON()` verbatim, and `JournalOffer` carries
# only offerId/blobSha256/postedAt/ttlSec/wantColour/wantAmount/quote/status/statusAt. The
# poster's successful read-back (`phase=verify result=ok`) only LOGS, and `statusAt` stays equal
# to `postedAt` because reconciliation rewrites a status only when it CHANGED. So the preference
# below is dead code today and says so on every run (`journalVerifiedField=absent`); it costs
# nothing and turns on by itself if a kernel ever records the marker.
#
# A QUOTED heredoc, so nothing here is expanded by this shell.
read -r -d '' JOURNAL_PROBE_JS <<'PROBE_JS' || true
const api = (process.env.ZSWAP_API || "http://kernel:9999").replace(/\/$/, "");
// Both knobs arrive through `dc exec -e`; anything unreadable falls back to the default rather
// than to NaN (which would make the loop exit on its first pass).
const secs = (raw, fallback) => {
  const n = Number(raw);
  return Number.isFinite(n) && n >= 0 ? n : fallback;
};
const budgetMs = secs(process.env.POSTER_PROBE_WAIT_S, 90) * 1000;
const pollMs = Math.max(0.5, secs(process.env.POSTER_PROBE_POLL_S, 3)) * 1000;
// The kernel's status vocabulary is exactly five strings (API.md: `GET /v1/offers/:hash/status`
// → live | consumed | cancelled | expired | not_found). These three mean the offer is over.
const TERMINAL = ["consumed", "cancelled", "expired"];
const verifiedMark = (offer) => offer.verifiedAt ?? offer.kernelVerifiedAt ?? offer.kernelSeenAt ?? null;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const out = [];
const r = await fetch("http://127.0.0.1:9977/journal", { signal: AbortSignal.timeout(10000) }).catch(() => null);
if (!r || !r.ok) { console.log("fetch=fail"); process.exit(0); }
const j = await r.json().catch(() => null);
if (!j || typeof j !== "object") { console.log("fetch=unparseable"); process.exit(0); }
out.push("fetch=ok");
// The journal is keyed by NETWORK + GIVE-TOKEN at this pin, not by a contract address —
// kernel #69 deleted the contract, and re-keying it is what makes "these coins belong to
// this chain" checkable at all now.
out.push("networkId=" + (j.networkId ?? "?"));
out.push("giveColour=" + (j.giveColour ?? "?"));
const coins = j.coins && typeof j.coins === "object" ? j.coins : {};
let total = 0;
const live = [];   // every LIVE offer, newest first (sorted below)
let newest = null; // newest offer of any status, for a journal with no live entry at all
let verifiedField = "absent";
for (const [nonce, coin] of Object.entries(coins)) {
  for (const offer of coin.offers ?? []) {
    total += 1;
    if (newest === null || String(offer.postedAt) > String(newest.offer.postedAt)) newest = { nonce, coin, offer };
    if (offer.status === "live") live.push({ nonce, coin, offer });
    if (verifiedMark(offer) !== null) verifiedField = "present";
  }
}
out.push("journalCoins=" + Object.keys(coins).length);
out.push("journalOffers=" + total);
out.push("journalVerifiedField=" + verifiedField);
live.sort((a, b) => String(b.offer.postedAt).localeCompare(String(a.offer.postedAt)));
// Candidate order: a poster-verified live entry first (FR-002, absent today), then live
// entries newest first. At most TWO are polled — the pick, and ONE fallback if it went
// terminal. A journal whose two newest live offers are both over is a finding, not a race.
const ordered = [];
for (const entry of live.filter((e) => verifiedMark(e.offer) !== null).concat(live)) {
  if (!ordered.some((o) => o.offer.offerId === entry.offer.offerId)) ordered.push(entry);
}
const candidates = ordered.slice(0, 2).map((entry, i) => ({
  ...entry,
  kind: i > 0 ? "live-fallback" : verifiedMark(entry.offer) !== null ? "verified" : "live",
}));
if (candidates.length === 0 && newest !== null) candidates.push({ ...newest, kind: "newest" });
if (candidates.length === 0) { console.log(out.join(String.fromCharCode(10))); process.exit(0); }

// ── the wait ────────────────────────────────────────────────────────────────
const startedAt = Date.now();
const waited = () => Date.now() - startedAt;
let answer = null;      // { pick, body } once the kernel served one
let unparseable = null; // { pick } — served 200 with no computed view
let pick = candidates[0];
let lastHttp = "";      // last HTTP code from the blob route: what `kernel=fail:<x>` reports
let lastStatus = "";    // the most informative thing the kernel said (status route wins)
let polls = 0;
let fellBack = "no";
for (let i = 0; i < candidates.length; i++) {
  pick = candidates[i];
  const id = String(pick.offer.offerId);
  let terminal = null;
  for (;;) {
    polls += 1;
    // The blob route FIRST: it is the answer every assertion below needs.
    const k = await fetch(api + "/v1/offers/" + id, { signal: AbortSignal.timeout(15000) }).catch(() => null);
    if (k && k.ok) {
      lastHttp = String(k.status);
      const o = await k.json().catch(() => null);
      if (!o || !o.computed) { lastStatus = "unparseable"; unparseable = { pick }; break; }
      const st = String(o.computed.status ?? "");
      lastStatus = st === "" ? lastHttp : st;
      answer = { pick, body: o };
      // `GET /v1/offers/:hash` resolves archived offers, so a 200 can itself be terminal. The
      // answer is KEPT anyway: if there is no fallback to try, "served, but over" is a far more
      // useful verdict than "never served", and the LIVE assertion below names the status.
      if (TERMINAL.includes(st)) terminal = st;
      break;
    }
    lastHttp = k ? String(k.status) : "unreachable";
    lastStatus = lastHttp;
    // 404 means "not indexed yet" OR "gone". Only the status route can tell the two apart,
    // and it is only worth asking when the probe is about to sleep.
    const s = await fetch(api + "/v1/offers/" + id + "/status", { signal: AbortSignal.timeout(10000) }).catch(() => null);
    if (s && s.ok) {
      const st = String(((await s.json().catch(() => null)) ?? {}).status ?? "");
      if (st !== "") lastStatus = st;
      if (TERMINAL.includes(st)) { terminal = st; break; }
    }
    if (waited() + pollMs > budgetMs) break;
    await sleep(pollMs);
  }
  if (unparseable !== null) break;
  if (terminal !== null && i + 1 < candidates.length && waited() < budgetMs) {
    answer = null; // the fallback entry becomes the assertions' subject, not this dead one
    fellBack = "yes:" + terminal;
    continue;
  }
  break;
}
if (answer !== null) pick = answer.pick;

// ── the pick, and how long it took ──────────────────────────────────────────
// Emitted for the FINAL candidate only: the shell reads each key once (`head -1`).
out.push("picked=" + pick.kind);
out.push("nonce=" + pick.nonce);
out.push("offerId=" + pick.offer.offerId);
out.push("journalStatus=" + pick.offer.status);
out.push("coinNullifier=" + (pick.coin.nullifier ?? "none"));
out.push("coinType=" + (pick.coin.type ?? "?"));
out.push("coinValue=" + (pick.coin.value ?? "?"));
out.push("coinState=" + (pick.coin.state ?? "?"));
out.push("journalQuoteSponsored=" + ((pick.offer.quote ?? {}).sponsored === true));
out.push("kernelBudgetS=" + budgetMs / 1000);
out.push("kernelPollS=" + pollMs / 1000);
out.push("kernelWaitS=" + (waited() / 1000).toFixed(1));
out.push("kernelPolls=" + polls);
out.push("kernelLastStatus=" + (lastStatus === "" ? "none" : lastStatus));
out.push("kernelFellBack=" + fellBack);
if (answer === null) {
  out.push("kernel=" + (unparseable === null ? "fail:" + (lastHttp === "" ? "unreachable" : lastHttp) : "unparseable"));
  console.log(out.join(String.fromCharCode(10)));
  process.exit(0);
}
const o = answer.body;
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
log "poster: the exact-coin guarantee (kernel wait up to ${PROBE_WAIT_S}s, every ${PROBE_POLL_S}s)"
# `|| true`: a poster that is down makes `dc exec` fail, and this must report that rather
# than let `set -e` end the run.
FIELDS="$(dc exec -T \
  -e "POSTER_PROBE_WAIT_S=${PROBE_WAIT_S}" \
  -e "POSTER_PROBE_POLL_S=${PROBE_POLL_S}" \
  offer-poster bun -e "$JOURNAL_PROBE_JS" 2>/dev/null || true)"
field() {  # field <key> — one flat key=value line from the probe
  printf '%s\n' "$FIELDS" | sed -n "s/^$1=//p" | head -1 || true
}

if [[ "$FIELDS" != *"fetch=ok"* ]]; then
  fail "could not read the poster's journal (${FIELDS:-no output})"
  exit 1
fi
J_OFFERS="$(field journalOffers)"
info "the journal records $(field journalCoins) coin(s) and ${J_OFFERS:-0} offer(s) on network $(field networkId), give colour $(field giveColour | cut -c1-16)…"
OFFER_ID="$(field offerId)"
if [[ -z "${OFFER_ID:-}" ]]; then
  fail "the journal records no offer at all, yet /health reported ${POSTED} produced offer(s)"
  exit 1
fi
# `picked` says WHICH entry the probe settled on, and the phrasing has to stay honest: the
# fallback is NOT the newest one.
case "$(field picked)" in
  live)          PICKED_AS="the newest live one" ;;
  verified)      PICKED_AS="the newest one the poster has verified against the kernel" ;;
  live-fallback) PICKED_AS="the next-newest live one — the newest reached a terminal status" ;;
  newest)        PICKED_AS="the newest one of any status; the journal holds no live entry" ;;
  *)             PICKED_AS="the newest $(field picked) one" ;;
esac
info "checking offer ${OFFER_ID:0:16}… (${PICKED_AS}), minted on coin nonce $(field nonce)"

COIN_NULL="$(field coinNullifier)"
KERNEL_STATUS="$(field kernelStatus)"
KERNEL_NULL="$(field kernelNullifier)"
KERNEL_NULL_COUNT="$(field kernelNullifierCount)"
# The wait, as the probe measured it. `kernelBudgetS` is the probe's EFFECTIVE budget (it
# falls back to its own default if the env value did not parse), so the failure line below
# quotes what was actually waited, not what was asked for.
KERNEL_WAIT_S="$(field kernelWaitS)"
KERNEL_LAST_STATUS="$(field kernelLastStatus)"
KERNEL_BUDGET_S="$(field kernelBudgetS)"
[[ -n "${KERNEL_BUDGET_S:-}" ]] || KERNEL_BUDGET_S="$PROBE_WAIT_S"
if [[ "$(field kernelFellBack)" == yes:* ]]; then
  info "the newest live offer had already reached status '$(field kernelFellBack | sed 's/^yes://' || true)' —"
  info "somebody settled or cancelled it while this ran; asserting the next-newest live one instead"
fi
if [[ "$(field journalVerifiedField)" == "absent" ]]; then
  dim  "the journal exposes no per-offer kernel-verification marker at this kernel pin, so the"
  dim  "probe waits for the kernel itself — that wait is the kernelWait below"
fi

# ONE failure for ONE cause. When the kernel never served the offer, every assertion
# below would read an EMPTY field and fail — five failures describing the clock, not the stack.
# That is precisely what the 2026-09-04 e2e run produced, so the dependent assertions are
# SKIPPED here and named, never evaluated on empty values.
KERNEL_SERVED=no
if [[ "$FIELDS" == *"kernel=ok"* ]]; then
  KERNEL_SERVED=yes
fi

if [[ "$KERNEL_SERVED" != "yes" ]]; then
  if [[ "$FIELDS" == *"kernel=unparseable"* ]]; then
    fail "the kernel answered 200 for offer ${OFFER_ID:0:16}… but the body carried no computed view (waited ${KERNEL_WAIT_S:-?}s of ${KERNEL_BUDGET_S}s)"
  else
    fail "the kernel did not serve offer ${OFFER_ID:0:16}… (waited ${KERNEL_WAIT_S:-?}s of ${KERNEL_BUDGET_S}s in $(field kernelPolls) poll(s), last status ${KERNEL_LAST_STATUS:-unknown})"
  fi
  info "SKIPPED, not failed — the five assertions below read the kernel's view of that offer and"
  info "would all report empty fields: LIVE status, exactly one input nullifier, nullifier equality,"
  info "one give leg + one want leg, and the whole-coin give amount. The sponsorship read needs the"
  info "same two colours and is skipped with them."
  info "the poster's own log says whether the offer was ever served — 'phase=verify result=ok' is it:"
  dim  "docker compose logs --tail=120 offer-poster | grep ${OFFER_ID:0:12}"
  info "raise the wait with POSTER_PROBE_WAIT_S=<seconds> (current ${KERNEL_BUDGET_S}s, polling every $(field kernelPollS)s)"
else
  ok "the kernel served offer ${OFFER_ID:0:16}… after ${KERNEL_WAIT_S:-?}s ($(field kernelPolls) poll(s), budget ${KERNEL_BUDGET_S}s)"
  if [[ "$KERNEL_STATUS" == "live" ]]; then
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
fi

# ── the offer as posted is SPONSORABLE ───────────────────────────────────────
echo
log "poster: sponsorship"
GIVE_TOKEN="$(field giveToken)"
GIVE_AMOUNT="$(field giveAmount)"
WANT_TOKEN="$(field wantToken)"
WANT_AMOUNT="$(field wantAmount)"
if [[ "$KERNEL_SERVED" != "yes" ]]; then
  # Named in the skip above and counted there: the two colours come from the same kernel read
  # that never arrived, so asserting here would be the sixth failure of one cause (issue 00017).
  info "SKIPPED — the kernel never served that offer (see the single failure above), so its two"
  info "colours are unknown and there is nothing to ask /v1/quote about."
elif [[ "$GIVE_TOKEN" =~ ^[0-9a-f]{64}$ && "$WANT_TOKEN" =~ ^[0-9a-f]{64}$ ]]; then
  QUOTE="$(curl -fsS --max-time 20 \
    "${KERNEL}/v1/quote?from_token=${GIVE_TOKEN}&to_token=${WANT_TOKEN}&from_amount=${GIVE_AMOUNT}&to_amount=${WANT_AMOUNT}" \
    2>/dev/null | tr -d '\n' || true)"
  SPONSORED="$(json_bool "$QUOTE" sponsored)"
  SUGGESTED="$(json_str "$QUOTE" suggested_to_amount)"
  # THE POSTER'S OWN VERDICT AT POST TIME, out of the journal. `poster-journal.ts` records a
  # `QuoteSnapshot` per offer whose `sponsored` is the quote's verdict WHEN THE OFFER WAS BUILT.
  AT_POST="$(field journalQuoteSponsored)"

  if [[ -z "$QUOTE" ]]; then
    fail "GET /v1/quote for the poster's own legs did not answer"
  else
    # ── THE HARD ASSERTION: it was sponsorable WHEN POSTED ──────────────────
    #
    # This is the poster's actual contract — "size the want leg from GET /v1/quote so the offer
    # lands on the sponsorship threshold and the batcher pays its Celestia fee" — and it is a
    # claim about the poster, not about the clock.
    if [[ "$AT_POST" == "true" ]]; then
      ok "the poster's own quote snapshot records this offer as SPONSORED when it was built"
    else
      fail "the journal's quote snapshot for this offer records sponsored=${AT_POST:-unreadable}
            — the poster did not size the want leg onto the sponsorship threshold. That is the
            poster's job every tick; a forced OFFER_POSTER_WANT_AMOUNT also produces this."
    fi

    # ── AND THE LIVE READING, which is time-sensitive BY CONSTRUCTION ───────
    #
    # `sponsored` is `to_amount <= suggested_to_amount` (packages/node/market-mock.ts), and
    # `suggested` is recomputed from TODAY'S reference prices with the 250 bps discount already
    # applied. An offer's want leg is FIXED when it is posted, so ANY move in the give token's
    # price against the want token's since then flips this to false without anything being
    # wrong.
    #
    # THAT MATTERS MUCH MORE AT THIS PIN, and it is a direct consequence of kernel #69. The
    # poster used to mint a fresh coin every tick, so the newest live offer was never older than
    # ~60 s. It cannot mint now: once the POSTER_PREMINT_COUNT pre-minted coins are all live it
    # reports `insufficient_inventory` and posts nothing new, so the newest live offer can be
    # tens of minutes old — and the `prices` profile refreshes CoinGecko inside the same gate.
    # MEASURED on this phase's gate: run 1 read `sponsored=true`; two price refreshes later run 3
    # read `false` on an offer asking 0.0453 % above the by-then-current suggestion.
    #
    # So it is REPORTED with the drift rather than asserted. The property it was standing in for
    # is asserted above, against the snapshot, where the clock cannot reach it.
    if [[ "$SPONSORED" == "true" ]]; then
      ok "and GET /v1/quote still says SPONSORED right now (the reference has not moved past it)"
    else
      warn "GET /v1/quote says sponsored=${SPONSORED:-unreadable} RIGHT NOW — the reference moved after the offer was posted"
      info "want ${WANT_AMOUNT} vs suggested_to_amount ${SUGGESTED:-?} for the same give amount."
      info "The want leg is fixed at post time; \`suggested\` is recomputed from today's prices."
      info "At this pin the book is BOUNDED (kernel #69: the poster cannot mint), so the newest"
      info "live offer can be minutes old — see docs/KNOWN-LIMITATIONS.md. Refill to get a fresh"
      info "one: docker compose run --rm issuer-fund ${GIVE_NAME} ${GIVE_AMOUNT} <poster-seed> 5"
    fi
    info "give ${GIVE_AMOUNT} of ${GIVE_TOKEN:0:12}… → want ${WANT_AMOUNT} of ${WANT_TOKEN:0:12}…"
    info "suggested_to_amount=${SUGGESTED:-?}  from_source=$(json_str "$QUOTE" from_source)  to_source=$(json_str "$QUOTE" to_source)"
  fi
else
  fail "could not read the offer's two colours from the kernel"
fi

# ── THE FIRST OFFER WAS PRICED TOO (00025; organizer issues/00023) ───────────
#
# WHY THIS BLOCK EXISTS, and why everything above it passed while the stack was wrong.
#
# `up.sh` used to start `offer-poster` in the same `docker compose up` as everything else, and
# `issuer-registrar` — the `replicas: 0` one-shot that gives the kernel each colour's name,
# decimals AND `asset_id` — runs BY HAND, ~2 minutes later. Inside that window the kernel's
# `GET /v1/quote` answers an unknown colour with a FABRICATED $1 per BASE UNIT
# (`source: "demo-fallback"`, `market_rate: 1`) and still reports `sponsored: true`, because
# that flag is computed arithmetically from the fabricated prices instead of by the batcher's
# own gate. The poster believed it. Measured on the 00020 phase-G gate: ticks 1 and 2 offered
# 1000000 base units of TWBTC (8 decimals, ~$790) for 975000 base units of TWETH (18 decimals,
# ~$0.000000002) — ELEVEN ORDERS OF MAGNITUDE off — and the solver's ladder derivation PREFERRED
# them, because a taker paying 10^-11 of the reference is the cheapest fill on the book.
#
# EVERY ASSERTION ABOVE STILL PASSED, and that is the lesson: the sponsorship block asserts the
# NEWEST live offer and the take settles the NEWEST live offer, and by the time verify runs the
# newest offers are fed-priced. The two wrong ones are the OLDEST two. So this block asserts the
# other end of the journal, plus two claims that hold for every tick ever run.
#
#   the log        ZERO `demo-fallback` lines and ZERO `market_rate=1` quote lines, over the
#                  WHOLE log rather than a tail — the mispriced ticks are the first ones.
#   the journal    ZERO recorded offers whose own quote snapshot names a fallback source or a
#                  market rate of exactly 1. This is the authoritative form of the same claim:
#                  `QuoteSnapshot` (deploy/scripts/lib/poster-journal.ts) stores `fromSource`,
#                  `toSource`, `marketRate`, `sponsorDiscount` and `sponsored` AS THE POSTER WAS
#                  TOLD THEM when the offer was built, so the clock cannot reach it.
#   the oldest     the OLDEST live offer, re-quoted through `GET /v1/quote` with its exact legs:
#                  both sources are market data, and its `discount` is still within a band of
#                  the kernel's OWN `sponsor_discount`.
#   the ordering   `docker inspect`: the poster's `StartedAt` is later than the registrar
#                  container's `FinishedAt`. The structural claim, independent of any log.
#
# ── WHAT IS ASSERTED AND WHAT IS REPORTED, and why they differ ───────────────
# `sponsored` on a LIVE re-quote is `to_amount <= suggested_to_amount`, and `suggested` is
# recomputed from TODAY'S prices — so it is true iff the reference happened to move in the
# favourable direction since the offer was posted. Measured on the 00020 phase-E and phase-G
# gates: the same offer read `sponsored=true` on one run and `false` two price refreshes later,
# 0.0453 % above the by-then-current suggestion. On the OLDEST offer, which is the first tick of
# the stack, that is at its most stale. So `sponsored` is ASSERTED against the journal snapshot
# (where it is a fact about the poster) and REPORTED with the drift on the live re-quote.
#
# The BAND is the assertable form of the same property, and it is generous on purpose:
# `POSTER_PRICE_BAND` (default 0.05, i.e. five percentage points) swallows any real price drift
# while still failing the 00023 offer by a factor of ~20 — its `discount` against a corrected
# reference is ~1.0 against a threshold of 0.025.
echo
log "poster: first offer priced (the OLDEST live offer, not the newest)"

# Five percentage points of drift tolerance on `discount` vs the kernel's own
# `sponsor_discount`. Set POSTER_PRICE_BAND=0 to assert the post-time equality exactly (it will
# fail on any price refresh; that is what the band is for).
PRICE_BAND="${POSTER_PRICE_BAND:-0.05}"

# float_within <a> <b> <tolerance> — |a − b| <= tol, exit 2 when either side is unreadable.
#
# `awk`, because bash has no floating point at all and these verify scripts take no dependency
# a stock macOS box lacks (`scripts/issuer-token-names.sh` and the issuer's registrar entrypoint
# already use it). `</dev/null` so awk cannot consume the caller's stdin — the same hazard that
# ate five of six lines of a `while read` loop in 00020 phase G.
float_within() {
  awk -v a="${1:-}" -v b="${2:-}" -v t="${3:-0}" 'BEGIN {
    if (a == "" || b == "") { exit 2 }
    d = a - b; if (d < 0) { d = -d }
    exit (d <= t) ? 0 : 1
  }' </dev/null
}

# ts_key <RFC3339-nano> — a fixed-width digit string that compares correctly as a STRING.
#
# Docker formats timestamps with Go's RFC3339Nano, which TRIMS TRAILING ZEROS from the
# fractional second — so `2026-09-09T14:07:01.4788068Z` and `2026-09-09T14:07:02.100311Z` differ
# in length and a plain string comparison of the two is wrong. The fraction is therefore padded
# to nine digits and every separator dropped, giving 23 digits every time. Compared as a string
# rather than a number on purpose: 23 significant digits do not survive a double.
ts_key() {
  awk -v t="${1:-}" 'BEGIN {
    if (t == "") { exit 0 }
    sub(/Z$/, "", t)
    n = index(t, ".")
    if (n > 0) { base = substr(t, 1, n - 1); frac = substr(t, n + 1) } else { base = t; frac = "" }
    while (length(frac) < 9) { frac = frac "0" }
    frac = substr(frac, 1, 9)
    gsub(/[^0-9]/, "", base)
    print base frac
  }' </dev/null
}

# ── (a) the poster's WHOLE log ───────────────────────────────────────────────
# Not `--tail`: the offers this block exists to catch are the FIRST ones the poster ever posted.
# `|| true` on the capture and on every count, for the reason in this file's header — a `grep`
# that legitimately matches nothing exits 1, `pipefail` makes that the pipeline's status and
# `set -e` would kill the script at exactly the clean state being described.
POSTER_LOG="$(dc logs --no-color offer-poster 2>/dev/null || true)"
if [[ -z "${POSTER_LOG:-}" ]]; then
  fail "docker compose logs offer-poster produced nothing — the log cannot be checked for
        demo-fallback quotes. That is not a pass: the poster has posted offers, so it has
        logged."
else
  # `demo-fallback` is the kernel's answer for a colour it has never been told about; `fallback`
  # is the deterministic colour-hash price for a colour it knows but cannot map to an asset.
  # `deploy/scripts/lib/poster-quote.ts` treats both as NOT market data (`DEMO_SOURCES`), and
  # the poster warns on either, so both are counted — separately, because they mean different
  # things to whoever reads the failure.
  LOG_DEMO="$(printf '%s\n' "$POSTER_LOG" | grep -c 'demo-fallback' || true)"
  # `market_rate=1` and NOT `market_rate=1.0234…` or `market_rate=15`: the field is printed by
  # `formatLogFields` as `String(number)`, so the demo answer is the exact three characters
  # `=1` at a field boundary. A genuine rate of exactly 1 would need two colours at identical
  # per-base-unit prices, which the shipped pair (8-decimal TWBTC, 18-decimal TWETH) cannot be.
  LOG_RATE1="$(printf '%s\n' "$POSTER_LOG" | grep -cE 'market_rate=1([^0-9.]|$)' || true)"
  LOG_LINES="$(printf '%s\n' "$POSTER_LOG" | grep -c '' || true)"
  if [[ "${LOG_DEMO:-0}" == "0" && "${LOG_RATE1:-0}" == "0" ]]; then
    ok "the poster's whole log (${LOG_LINES:-0} lines) carries NO demo-fallback quote and NO market_rate=1"
  else
    fail "the poster quoted from fabricated prices: ${LOG_DEMO:-?} demo-fallback line(s) and ${LOG_RATE1:-?} market_rate=1 quote line(s)
          in ${LOG_LINES:-0} log lines. The kernel prices a colour it has not been told about at
          \$1 per BASE UNIT and still answers sponsored:true, so those ticks posted real,
          settleable offers off by orders of magnitude (issues/00023, issues/00024). up.sh starts
          the poster only after issuer-registrar binds the colours; a poster started by hand, or
          one whose registrar ran late, produces exactly this."
    dim  "$(printf '%s\n' "$POSTER_LOG" | grep -E 'demo-fallback|market_rate=1([^0-9.]|$)' | head -4 | tr '\n' ' ' || true)"
  fi
fi

# ── (b) the journal's OLDEST live offer, and every offer's recorded sources ──
#
# A QUOTED heredoc, so nothing here is expanded by this shell. Read from inside the container
# for the same reason the exact-coin probe is: the interesting values are nested and this host
# has neither jq nor bun.
read -r -d '' OLDEST_PROBE_JS <<'OLDEST_JS' || true
const r = await fetch("http://127.0.0.1:9977/journal", { signal: AbortSignal.timeout(10000) }).catch(() => null);
if (!r || !r.ok) { console.log("fetch=fail"); process.exit(0); }
const j = await r.json().catch(() => null);
if (!j || typeof j !== "object") { console.log("fetch=unparseable"); process.exit(0); }
const out = ["fetch=ok"];
// `DEMO_SOURCES` in deploy/scripts/lib/poster-quote.ts, restated: neither is market data.
const BAD = ["demo-fallback", "fallback"];
const coins = j.coins && typeof j.coins === "object" ? j.coins : {};
const entries = [];
for (const [nonce, coin] of Object.entries(coins)) {
  for (const offer of coin.offers ?? []) entries.push({ nonce, coin, offer });
}
// EVERY offer the journal remembers, not just the live ones: an offer that was consumed or
// expired was still posted at that price, and a stack that ever posted one is a stack whose
// ordering was wrong.
let badSource = 0;
let rate1 = 0;
let noQuote = 0;
for (const e of entries) {
  const q = e.offer.quote ?? null;
  if (!q || typeof q !== "object") { noQuote += 1; continue; }
  if (BAD.includes(String(q.fromSource)) || BAD.includes(String(q.toSource))) badSource += 1;
  if (Number(q.marketRate) === 1) rate1 += 1;
}
out.push("offers=" + entries.length);
out.push("badSourceOffers=" + badSource);
out.push("rate1Offers=" + rate1);
out.push("noQuoteOffers=" + noQuote);
// The OLDEST LIVE one, by the journal's own `postedAt`. Ascending, i.e. the exact opposite of
// the exact-coin probe above — which is the whole point of this block.
const live = entries.filter((e) => e.offer.status === "live");
live.sort((a, b) => String(a.offer.postedAt).localeCompare(String(b.offer.postedAt)));
out.push("liveOffers=" + live.length);
if (live.length === 0) { console.log(out.join(String.fromCharCode(10))); process.exit(0); }
const pick = live[0];
const q = pick.offer.quote ?? {};
out.push("oldestOfferId=" + pick.offer.offerId);
out.push("oldestPostedAt=" + pick.offer.postedAt);
// The offer's own legs, out of the journal: the give colour is the journal's key and the give
// amount is the coin's WHOLE value (every offer spends its coin entire, no change output).
out.push("oldestGiveColour=" + (j.giveColour ?? "?"));
out.push("oldestGiveAmount=" + (pick.coin.value ?? "?"));
out.push("oldestWantColour=" + (pick.offer.wantColour ?? "?"));
out.push("oldestWantAmount=" + (pick.offer.wantAmount ?? "?"));
out.push("oldestQuoteSponsored=" + (q.sponsored === true));
out.push("oldestQuoteFromSource=" + (q.fromSource ?? "absent"));
out.push("oldestQuoteToSource=" + (q.toSource ?? "absent"));
out.push("oldestQuoteMarketRate=" + (q.marketRate ?? "absent"));
out.push("oldestQuoteSponsorDiscount=" + (q.sponsorDiscount ?? "absent"));
console.log(out.join(String.fromCharCode(10)));
OLDEST_JS

OLDEST="$(dc exec -T offer-poster bun -e "$OLDEST_PROBE_JS" 2>/dev/null || true)"
oldest_field() { printf '%s\n' "$OLDEST" | sed -n "s/^$1=//p" | head -1 || true; }

if [[ "$OLDEST" != *"fetch=ok"* ]]; then
  fail "could not read the poster's journal for the oldest-offer check (${OLDEST:-no output})"
else
  J_ALL="$(oldest_field offers)"
  J_BAD="$(oldest_field badSourceOffers)"
  J_RATE1="$(oldest_field rate1Offers)"
  J_NOQ="$(oldest_field noQuoteOffers)"
  if [[ "${J_BAD:-1}" == "0" && "${J_RATE1:-1}" == "0" ]]; then
    ok "all ${J_ALL:-0} offer(s) the journal remembers were quoted from MARKET data (0 fallback sources, 0 at market_rate 1)"
  else
    fail "of ${J_ALL:-?} offers in the poster's journal, ${J_BAD:-?} were quoted from a fallback
          source and ${J_RATE1:-?} at a market rate of exactly 1. Those are the offers issues/00023
          describes: posted before issuer-registrar bound this stack's colours, priced by the
          kernel at \$1 per BASE UNIT, reported sponsorable, and preferred by the solver's ladder."
  fi
  if [[ "${J_NOQ:-0}" != "0" ]]; then
    warn "${J_NOQ} journal offer(s) carry no quote snapshot at all — they cannot be checked either way"
  fi

  OLD_ID="$(oldest_field oldestOfferId)"
  if [[ -z "${OLD_ID:-}" ]]; then
    fail "the journal records $(oldest_field liveOffers) live offer(s) but none could be read as the oldest"
  else
    OLD_GIVE_C="$(oldest_field oldestGiveColour)"
    OLD_GIVE_A="$(oldest_field oldestGiveAmount)"
    OLD_WANT_C="$(oldest_field oldestWantColour)"
    OLD_WANT_A="$(oldest_field oldestWantAmount)"
    OLD_FROM_S="$(oldest_field oldestQuoteFromSource)"
    OLD_TO_S="$(oldest_field oldestQuoteToSource)"
    OLD_SPONS="$(oldest_field oldestQuoteSponsored)"
    OLD_RATE="$(oldest_field oldestQuoteMarketRate)"
    info "oldest LIVE offer ${OLD_ID:0:16}… posted $(oldest_field oldestPostedAt) — $(oldest_field liveOffers) live of ${J_ALL:-?} recorded"
    info "give ${OLD_GIVE_A} of ${OLD_GIVE_C:0:12}… → want ${OLD_WANT_A} of ${OLD_WANT_C:0:12}…"
    info "its own snapshot: from_source=${OLD_FROM_S} to_source=${OLD_TO_S} market_rate=${OLD_RATE} sponsored=${OLD_SPONS}"

    # THE ASSERTION THE CLOCK CANNOT REACH: what the poster was TOLD when it built this offer.
    case "${OLD_FROM_S}:${OLD_TO_S}" in
      feed:feed|feed:seed|seed:feed|seed:seed)
        ok "the OLDEST live offer was quoted from market data on BOTH legs (${OLD_FROM_S}/${OLD_TO_S})" ;;
      *)
        fail "the OLDEST live offer was quoted from '${OLD_FROM_S}'/'${OLD_TO_S}', not feed/seed.
              A 'demo-fallback' leg means the kernel had never been told that colour when this
              offer was built, i.e. the poster started before issuer-registrar (issues/00023);
              'fallback' means the colour is registered with no asset_id (issues/00024)." ;;
    esac
    if [[ "$OLD_SPONS" == "true" ]]; then
      ok "…and its own quote snapshot recorded it SPONSORED when it was built"
    else
      fail "the oldest live offer's quote snapshot records sponsored=${OLD_SPONS:-unreadable} — the
            poster did not size its want leg onto the sponsorship threshold on that tick."
    fi

    # ── the live re-quote, with the offer's EXACT legs ──────────────────────
    if [[ "$OLD_GIVE_C" =~ ^[0-9a-f]{64}$ && "$OLD_WANT_C" =~ ^[0-9a-f]{64}$ ]]; then
      OLD_QUOTE="$(curl -fsS --max-time 20 \
        "${KERNEL}/v1/quote?from_token=${OLD_GIVE_C}&to_token=${OLD_WANT_C}&from_amount=${OLD_GIVE_A}&to_amount=${OLD_WANT_A}" \
        2>/dev/null | tr -d '\n' || true)"
      if [[ -z "$OLD_QUOTE" ]]; then
        fail "GET /v1/quote for the OLDEST live offer's own legs did not answer"
      else
        # `json_num` matches integers only, and every one of these is a JSON number that can
        # carry a fraction or a sign, so they are scraped with their own pattern here.
        quote_float() {  # quote_float <body> <key> — the raw JSON number, or nothing
          printf '%s' "$1" \
            | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?" \
            | sed "s/.*:[[:space:]]*//" | head -1 || true
        }
        OQ_FROM_S="$(json_str "$OLD_QUOTE" from_source)"
        OQ_TO_S="$(json_str "$OLD_QUOTE" to_source)"
        OQ_RATE="$(quote_float "$OLD_QUOTE" market_rate)"
        OQ_IMPLIED="$(quote_float "$OLD_QUOTE" implied_rate)"
        OQ_DISCOUNT="$(quote_float "$OLD_QUOTE" discount)"
        OQ_THRESHOLD="$(quote_float "$OLD_QUOTE" sponsor_discount)"
        OQ_SPONS="$(json_bool "$OLD_QUOTE" sponsored)"
        OQ_SUGGESTED="$(json_str "$OLD_QUOTE" suggested_to_amount)"
        info "re-quoted now: market_rate=${OQ_RATE:-?} implied_rate=${OQ_IMPLIED:-?} discount=${OQ_DISCOUNT:-?}"
        info "               sponsor_discount=${OQ_THRESHOLD:-?} from_source=${OQ_FROM_S:-?} to_source=${OQ_TO_S:-?} sponsored=${OQ_SPONS:-?}"

        # The kernel's CURRENT price provenance for those two colours. Unlike `sponsored`, this
        # is not a function of when the offer was posted.
        case "${OQ_FROM_S}:${OQ_TO_S}" in
          feed:feed|feed:seed|seed:feed|seed:seed)
            ok "the kernel still prices both of that offer's colours from market data (${OQ_FROM_S}/${OQ_TO_S})" ;;
          *)
            fail "GET /v1/quote now prices those colours '${OQ_FROM_S:-none}'/'${OQ_TO_S:-none}' — the
                  kernel's registry lost, or never had, this stack's colours (issues/00024)." ;;
        esac
        # THE BAND. `discount` is 1 − implied/market: it equals `sponsor_discount` exactly at
        # post time and drifts with the reference afterwards. The 00023 offer's discount against
        # a corrected reference is ~1.0, so this fails it by a factor of ~20 while tolerating
        # every real price move seen on a gate.
        BAND_RC=0
        float_within "${OQ_DISCOUNT:-}" "${OQ_THRESHOLD:-}" "$PRICE_BAND" || BAND_RC=$?
        case "$BAND_RC" in
          0) ok "…and its implied rate is still within ${PRICE_BAND} of the sponsorship threshold (discount ${OQ_DISCOUNT} vs ${OQ_THRESHOLD})" ;;
          2) fail "could not read discount / sponsor_discount off the re-quote: ${OLD_QUOTE:0:200}" ;;
          *) fail "the OLDEST live offer's implied rate is OUT OF BAND: discount=${OQ_DISCOUNT} against a
                   sponsor_discount of ${OQ_THRESHOLD} (tolerance ${PRICE_BAND}).
                   want ${OLD_WANT_A} vs suggested_to_amount ${OQ_SUGGESTED:-?} for give ${OLD_GIVE_A}.
                   This is the shape of issues/00023: an offer priced from a fabricated quote sits
                   orders of magnitude away from the reference and the solver's ladder prefers it." ;;
        esac
        # REPORTED, not asserted — see this block's header.
        if [[ "$OQ_SPONS" == "true" ]]; then
          ok "GET /v1/quote still calls that offer SPONSORED right now"
        else
          warn "GET /v1/quote says sponsored=${OQ_SPONS:-unreadable} for the oldest live offer right now"
          info "want ${OLD_WANT_A} vs suggested_to_amount ${OQ_SUGGESTED:-?}. The want leg is fixed at"
          info "post time and \`suggested\` is recomputed from today's prices, so on the OLDEST offer"
          info "of a bounded book this flips on any price refresh. The band above is the assertable"
          info "form of the same property; the post-time verdict is asserted off the journal."
        fi
      fi
    else
      fail "the oldest live offer's colours are not 64-hex (give '${OLD_GIVE_C}', want '${OLD_WANT_C}')"
    fi
  fi
fi

# ── (c) the ORDERING, off daemon-owned state ─────────────────────────────────
#
# The structural claim, and the only one here that does not depend on the poster having logged
# or journalled anything: the poster's container STARTED after the registrar's container
# FINISHED.
#
# The registrar is a `docker compose run` container (`oneoff=True`), so this must NOT filter
# `oneoff=False` the way scripts/verify-oneshots.sh does for compose-managed one-shots — and
# `up.sh` deliberately runs it WITHOUT `--rm` so that its exit code, its log and this timestamp
# survive the run at all.
#
# `docker ps -aq` lists newest first, so `head -1` is the run belonging to the most recent
# `./up.sh`. That matters: an ADDITIVE `./up.sh --with poster` re-runs the registrar (idempotent,
# `already=6`) while leaving an already-running poster alone, and the initial `up` of that run
# scale-downs the previous run container away — so the only registrar container left can be
# NEWER than the poster's start. That is not a violation of anything and it is not asserted as
# one; it is reported, with the two timestamps, and the property for the run that DID start the
# poster is the journal assertion above.
POSTER_CID="$(docker ps -aq \
  --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" \
  --filter "label=com.docker.compose.service=offer-poster" \
  --filter "label=com.docker.compose.oneoff=False" 2>/dev/null | head -1 || true)"
REG_CID="$(docker ps -aq \
  --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" \
  --filter "label=com.docker.compose.service=issuer-registrar" 2>/dev/null | head -1 || true)"
POSTER_STARTED_AT="$(docker inspect -f '{{.State.StartedAt}}' "${POSTER_CID:-none}" 2>/dev/null || true)"
REG_FINISHED_AT="$(docker inspect -f '{{.State.FinishedAt}}' "${REG_CID:-none}" 2>/dev/null || true)"
REG_CREATED_AT="$(docker inspect -f '{{.Created}}' "${REG_CID:-none}" 2>/dev/null || true)"
REG_STATUS="$(docker inspect -f '{{.State.Status}}' "${REG_CID:-none}" 2>/dev/null || true)"
REG_CODE="$(docker inspect -f '{{.State.ExitCode}}' "${REG_CID:-none}" 2>/dev/null || true)"

if [[ -z "${POSTER_CID:-}" || -z "${POSTER_STARTED_AT:-}" ]]; then
  fail "no offer-poster container to inspect in project '${COMPOSE_PROJECT_NAME}' — the ordering
        claim cannot be read (and this section got this far, so one exists)"
elif [[ -z "${REG_CID:-}" ]]; then
  fail "no issuer-registrar container in project '${COMPOSE_PROJECT_NAME}': the one-shot that binds
        this stack's colours left no record, so the bring-up order cannot be verified. up.sh runs
        it WITHOUT --rm exactly so that it does. A stack brought up by hand with
        \`docker compose run --rm --no-deps issuer-registrar\` produces this."
elif [[ "$REG_STATUS" != "exited" || "$REG_CODE" != "0" ]]; then
  fail "the issuer-registrar container is '${REG_STATUS:-unreadable}' with exit code ${REG_CODE:-unreadable}
        — the colours were never bound successfully, so nothing downstream can be priced."
else
  POSTER_KEY="$(ts_key "$POSTER_STARTED_AT")"
  REG_FIN_KEY="$(ts_key "$REG_FINISHED_AT")"
  REG_CRE_KEY="$(ts_key "$REG_CREATED_AT")"
  info "issuer-registrar finished ${REG_FINISHED_AT}"
  info "offer-poster     started  ${POSTER_STARTED_AT}"
  if [[ -z "$POSTER_KEY" || -z "$REG_FIN_KEY" ]]; then
    fail "could not read both timestamps (poster '${POSTER_STARTED_AT}', registrar '${REG_FINISHED_AT}')"
  elif [[ "$POSTER_KEY" > "$REG_FIN_KEY" ]]; then
    ok "offer-poster STARTED AFTER issuer-registrar FINISHED — its first quote could only be a priced one"
  elif [[ -n "$REG_CRE_KEY" && "$POSTER_KEY" < "$REG_CRE_KEY" ]]; then
    info "SKIPPED — this registrar container was CREATED after the poster started, so it belongs to"
    info "a LATER ./up.sh than the one that started the poster (an additive --with poster leaves a"
    info "running poster alone and re-runs the registrar idempotently, and that run's initial"
    info "\`up\` removes the previous registrar container). The ordering claim for the run that DID"
    info "start this poster is carried by the journal assertions above — every recorded offer,"
    info "including the oldest, was quoted from market data."
  else
    fail "offer-poster STARTED BEFORE issuer-registrar FINISHED: ${POSTER_STARTED_AT} < ${REG_FINISHED_AT}.
          That is the window issues/00023 describes — the kernel does not know the poster's colours
          yet, quotes them at \$1 per BASE UNIT and still says sponsored:true. ./up.sh holds the
          poster out of the initial \`docker compose up\` and starts it after the registrar; a
          poster started any other way has no such guarantee."
  fi
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
// `adoptedAt` at this pin; `mintedAt` was its name while the poster still minted. Reading
// whichever is present keeps this working across a re-pin in either direction.
coins.sort((a, b) => String(a.adoptedAt ?? a.mintedAt).localeCompare(String(b.adoptedAt ?? b.mintedAt)));
console.log("sizes=" + coins.slice(-2).map((c) => String(c.value)).join(","));
SIZES_JS
  SIZES="$(dc exec -T offer-poster bun -e "$SIZES_PROBE_JS" 2>/dev/null | sed -n 's/^sizes=//p' | head -1 || true)"
  FIRST_SIZE="${SIZES%%,*}"
  LAST_SIZE="${SIZES##*,}"
  if [[ -z "${SIZES:-}" || "$SIZES" == "fail" || "$FIRST_SIZE" == "$SIZES" ]]; then
    fail "could not read two adopted coin sizes from the journal (got '${SIZES:-nothing}')"
  elif [[ "$FIRST_SIZE" != "$LAST_SIZE" ]]; then
    ok "the last two adopted coins differ in size (${FIRST_SIZE} then ${LAST_SIZE} base units)"
  else
    fail "a range is configured but the last two adopted coins are both ${FIRST_SIZE} base units"
    info "AT THIS PIN THE RANGE IS A FILTER, NOT A DRAW: kernel #69 replaced the log-uniform"
    info "whole-coin draw (and deleted OFFER_POSTER_SIZE_SEED) with an inclusive base-unit"
    info "filter over coins the wallet ALREADY HOLDS. So a spread requires a WALLET with a"
    info "spread, and poster-inventory mints ONE exact size. Stock it yourself with several"
    info "issuer-fund <TOKEN> <size> <poster-seed> <count> calls at different sizes."
  fi
else
  info "no OFFER_POSTER_GIVE_MIN/_GIVE_MAX configured — poster-inventory mints ONE exact size,"
  info "so every offer is that size and the spread assertion does not apply (the shipped default)"
fi

# ── somebody else settles one of them ────────────────────────────────────────
echo
log "poster: a taker settles one poster offer"
if [[ "${POSTER_VERIFY_SKIP_TAKE:-false}" == "true" || "${POSTER_VERIFY_SKIP_TAKE:-false}" == "1" ]]; then
  warn "SKIP (POSTER_VERIFY_SKIP_TAKE=${POSTER_VERIFY_SKIP_TAKE}) — the offers above were"
  info "asserted LIVE and sponsorable, but nothing proved one can actually be settled."
else
  # ── the two token ids, from the issuer's registry ─────────────────────────
  # The driver takes 64-hex ids at this pin (kernel #69 deleted the offline
  # `expectedColour(name, contractAddress)` derivation with the contract), and the ids are
  # per chain. `issuer_token_id` is the same host-side reader verify-kernel and verify-solver
  # use, so all three describe the same tokens by construction.
  TAKE_GIVE_ID="$(issuer_token_id "$GIVE_NAME" || true)"
  TAKE_WANT_ID="$(issuer_token_id "$WANT_NAME" || true)"
  if [[ ! "$TAKE_GIVE_ID" =~ ^[0-9a-f]{64}$ || ! "$TAKE_WANT_ID" =~ ^[0-9a-f]{64}$ ]]; then
    fail "could not resolve the poster's legs from the issuer registry
          (${GIVE_NAME} -> ${TAKE_GIVE_ID:-?}, ${WANT_NAME} -> ${TAKE_WANT_ID:-?}).
          The \`poster\` profile requires \`issuer\`; ./up.sh adds it."
    exit 1
  fi

  # ── the taker's want-side inventory, from the ISSUER ──────────────────────
  # NEW AT THIS PIN, and not an optimisation: up to `KERNEL_REF=a608fa6…` the driver minted the
  # demanded token itself through the kernel's faucet circuit, and kernel #69 deleted that
  # circuit along with `deploy/scripts/lib/faucet-mint.ts`. Nothing but the issuer can produce
  # one of these tokens now.
  #
  # It runs BEFORE the driver because both open a facade on the taker's seed, and one facade
  # per seed is an SDK rule. `issuer-fund` reads the balance back and refuses to report success
  # unless it moved by exactly this amount, so a silent short-fund is not a failure mode here.
  info "funding e2e-taker (…${TAKE_TAKER_SEED: -4}) with ${TAKE_FUND_AMOUNT} base units of ${WANT_NAME} from the issuer"
  FUND_OUT="$(mktemp)"
  FUND_RC=0
  dc run --rm issuer-fund "$WANT_NAME" "$TAKE_FUND_AMOUNT" "$TAKE_TAKER_SEED" >"$FUND_OUT" 2>&1 || FUND_RC=$?
  FUND_RESULT="$(grep -m1 '^ISSUER_FUND_RESULT ' "$FUND_OUT" || true)"
  if (( FUND_RC != 0 )) || [[ -z "$FUND_RESULT" ]]; then
    sed 's/^/      /' "$FUND_OUT" >&2
    rm -f "$FUND_OUT"
    fail "could not fund the taker with ${WANT_NAME} — the take cannot pay for the offer.
          The manual form is: docker compose run --rm issuer-fund ${WANT_NAME} ${TAKE_FUND_AMOUNT} <taker-seed>"
    exit 1
  fi
  rm -f "$FUND_OUT"
  ok "the taker holds ${WANT_NAME}: $(printf '%s' "$FUND_RESULT" | sed -n 's/.* balanceAfter=\([0-9]*\).*/\1/p' | head -1 || true) base units"

  info "e2e-taker gets its NIGHT from …${TAKE_FUNDER_SEED: -4} inside the driver, then settles"
  info "one poster offer on chain. Two provings; this is the long one."
  TAKE_OUT="$(mktemp)"
  TAKE_RC=0
  dc run --rm --no-deps -T \
    -v "${REPO_ROOT}/scripts/driver:/app/stack-driver:ro" \
    -e "ZSWAP_API=http://kernel:9999" \
    -e "TAKER_SEED=${TAKE_TAKER_SEED}" \
    -e "FUNDER_SEED=${TAKE_FUNDER_SEED}" \
    -e "GIVE_TOKEN=${TAKE_GIVE_ID}" \
    -e "WANT_TOKEN=${TAKE_WANT_ID}" \
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
