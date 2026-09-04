#!/usr/bin/env bash
#
# Assertions for the `solver` profile — the `solver` section of ./verify.sh.
#
#   ./scripts/verify-solver.sh
#
# WHAT IT PROVES, and why each check is here rather than assumed:
#
#   relay reachable   GET /tokens over the PUBLISHED host port. The relay has no /health
#                     route; /tokens is its only unauthenticated public one, and it answers
#                     200 with an empty list when nothing is connected — so a 200 alone
#                     proves nothing about the solver, which is exactly why the checks below
#                     exist.
#   solver connected  GET /state, read from INSIDE the relay container. The route is
#                     loopback-only by design (an operator debug surface), so it is
#                     unreachable through the published port — docker's proxy arrives from
#                     the bridge network, not from 127.0.0.1. `connectedCount` is the only
#                     direct evidence that the WS handshake and its bearer succeeded.
#   ladder published  the two minted dev colours appear in /tokens. That union is built from
#                     what connected solvers advertise, which the solver derives from the
#                     MIRRORED BOOK — so this single assertion covers provisioning, book
#                     sync, derivation and publication at once. An empty list here is the
#                     silent failure the two one-shots exist to prevent.
#   quote round trip  EXACT equality, not a bound. The derivation applies no fee and no
#                     margin: rungs are the book's own whole-offer cumulative sums, and the
#                     relay's interpolation returns a rung's output verbatim when amountIn
#                     lands exactly on it. With the seeded offer that makes
#                     quote(WANT_AMOUNT) == GIVE_AMOUNT, to the unit — and WHOSE want and
#                     give those are is read from the maker offer itself (below).
#   refusals          three of them, because "it quoted something" is a weak claim on its
#                     own: below the ladder's first rung is 422 `unfulfillable`, the reverse
#                     direction and an unpriced colour are 503 `no_solver`, and tokenIn ==
#                     tokenOut is a 400 the schema layer owns. A relay that answered 200 to
#                     any of these would be quoting a fill nothing can honour.
#   journal           the solver's durable wallet-operation journal exists on its volume. It
#                     fails CLOSED at startup if it cannot be opened, so its presence is what
#                     makes "the solver is running" mean "the journal is usable".
#   intents UI        the page is served AND the same token set is reachable through its own
#                     /api/v1 edge. That second half is the browser-network property: a
#                     browser can only reach the relay through this proxy, so if it works
#                     from the host it works from the page.
#   status listener   the solver's read-only /status/* on :9100, from INSIDE the compose
#                     network: 200 with the bearer, 401 without it. It is deliberately not
#                     published to the host, so `docker compose exec` is the only way to
#                     reach it — and the pair of results is what proves the listener is on
#                     AND gated, rather than merely one of the two.
#   monitor           the solver-frontend site on the PUBLISHED port: /health 200 reporting
#                     the solver `reachable` (which it can only know by having authenticated
#                     against the listener above), /api/snapshot carrying a relay-connected
#                     solver with a non-empty published ladder, and /api/stream delivering a
#                     first SSE frame. The nested snapshot fields are read from inside the
#                     container with `bun -e`, for the same reason /state is: this host has
#                     no jq and no bun, and the verify scripts take no dependency a stock
#                     macOS box lacks.
#   health            THE CONTAINER HEALTHCHECK ITSELF, because a healthcheck is a thing that
#                     can be wrong. Since 00015 it asks the solver's own /health for `ready`
#                     (issues/00013); the claim worth checking is not "healthy now" but "stays
#                     healthy while the book churns", so `Health.Log` is SAMPLED every 10 s
#                     across a window longer than the five probes docker retains, and every
#                     non-zero exit ever seen is accumulated. Runs last, after minutes of real
#                     churn. `SOLVER_VERIFY_HEALTH_TRANSITION=1` additionally stops and starts
#                     the relay and then the solver, and records what each does.
#
# WHAT IT DELIBERATELY DOES NOT PROVE. The UI's swap flow needs a Midnight WALLET EXTENSION
# to sign an intent (`window.midnight`, the dapp-connector API), which no script on this host
# can provide. The quote half of that flow is asserted above; the take half is a manual step,
# and the scripted settlement proof is the P5 driver, not this script.
#
# ALSO NOT HERE: settlement itself. A take CONSUMES the offer it fills, so a script that
# settled would make its own next run fail with an empty book.
#
# ── LIVING BESIDE THE `poster` PROFILE (00011 FR-014) ───────────────────────
# The `poster` profile keeps a spread of its own offers on the same kernel book. Nothing this
# script asserts may depend on the book holding exactly one offer, and two things used to:
#
#   1. the re-seed decision, which asked "is the book EMPTY?". With a poster running the book
#      is never empty, so a stack that had lost its maker offer would have skipped the
#      re-seed and then failed the quote assertion for a reason the message did not name.
#      It now asks "is THE MAKER OFFER live?", by the content hash the one-shot's marker
#      records, and reports the total book size separately.
#   2. the exact-quote expectation, which came from MAKER_OFFER_GIVE_AMOUNT /
#      _WANT_AMOUNT in the environment. It now comes from `GET /v1/offers/<maker hash>` —
#      the offer's OWN legs — and the two dev colours resolved from minted-tokens.json are
#      cross-checked against that same offer, so a marker pointing at somebody else's offer
#      is a failure rather than a wrong expectation.
#
# The ladder assertion ("the relay advertises both dev colours") is unaffected by design: it
# asks whether two specific colours are in the relay's union, not how many are.
#
# The poster's own pair CANNOT collide with the maker's on this stack, and that is a property
# of the two sources rather than of a lucky choice: the poster mints its give leg from the
# FAUCET, which derives a colour from a preset NAME (WBTC), while the maker gives a colour
# `mint-test-tokens.ts` minted from a fixed domain separator that no preset name maps to. The
# assertions above do not rely on that — they identify the offer by hash — but it is why a
# poster offer can never be mistaken for the seeded one.
#
# ── THE ONE SIDE EFFECT THIS SCRIPT DOES HAVE (00011 B.5b) ──────────────────
# It re-seeds the book when there is no live maker offer left, and it does so LOUDLY.
#
# The seeded offer is not permanent. Two things end it, and neither is a defect:
#
#   * EXPIRY. On this chain an offer's life is min(ROOT_WINDOW_SECONDS, OFFER_TTL_SECONDS)
#     = 1 h whatever MAKER_OFFER_TTL_MINUTES asks for, because a shielded input can only be
#     proved against a Merkle root still inside the chain's window. A long `./up.sh --all`
#     plus a full `./verify.sh` can exceed that on its own.
#   * CONSUMPTION. The kernel archives an offer the moment ANY on-chain transaction spends
#     its input nullifier. A settled take does that — and so does an unrelated transfer from
#     the maker's own wallet whose coin selection happens to pick the coin the offer
#     reserved, which is exactly what the shielded-night book chain's taker funding does on
#     an `--all` run (it moves the maker's give colour out of the maker's own genesis wallet).
#
# Until 00011 this script answered an empty book with a WARN and SKIPPED its ladder and
# exact-quote assertions — the strongest ones it has — while still exiting 0. A section that
# passes without testing anything is worse than a red one. So: an empty book is now reported
# with the maker offer's ACTUAL terminal status (read by hash from the marker), the
# `maker-offer` one-shot is re-run with MAKER_OFFER_RESEED=true, and the assertions proceed
# on the fresh offer. If the re-seed fails, or the ladder does not come back inside its
# budget, the section FAILS. Set SOLVER_VERIFY_RESEED=false to forbid the side effect — in
# which case an empty book is a FAILURE, still never a silent skip.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"

require_docker
load_env
# Every fragment, not just solver: `dc exec` must resolve the service, and naming one profile
# makes compose call every other profile's containers orphans on each invocation.
use_all_profiles

BIND="${HOST_ADDR:-127.0.0.1}"
RELAY="http://${BIND}:${RELAY_HTTP_HOST_PORT:-13000}"
UI="http://${BIND}:${INTENTS_UI_HOST_PORT:-10700}"
KERNEL="http://${BIND}:${KERNEL_HOST_PORT:-9999}"
MONITOR="http://${BIND}:${SOLVER_FRONTEND_HOST_PORT:-10800}"

# How long the ladder may take to come back after a re-seed, and how long the monitor may take
# to report a relay-connected solver with a non-empty ladder. The second is spec SC-004's own
# budget (3 minutes from the solver turning healthy); the first is more generous because a
# re-seed has to prove and submit a transaction first.
LADDER_BUDGET_S="${SOLVER_LADDER_BUDGET_S:-300}"
MONITOR_BUDGET_S="${SOLVER_MONITOR_BUDGET_S:-180}"

# The seeded offer's shape. Defaulted here to the same values compose gives the one-shot, so
# an operator who changed them in .env gets assertions that follow.
GIVE_AMOUNT="${MAKER_OFFER_GIVE_AMOUNT:-500000}"
WANT_AMOUNT="${MAKER_OFFER_WANT_AMOUNT:-750000}"
SEEDED="yes"
[[ "${MAKER_OFFER_ENABLED:-true}" == "true" ]] || SEEDED="no"
[[ "${SOLVER_PROVISION_ENABLED:-true}" == "true" ]] || SEEDED="no"

FAILURES=0
fail() { err "$*"; FAILURES=$(( FAILURES + 1 )); }

log "solver: endpoints"
info "relay      ${RELAY}   (solver WS :${RELAY_WS_HOST_PORT:-19001})"
info "monitor    ${MONITOR}"
info "intents UI ${UI}"
info "status     http://solver:9100 (INSIDE the compose network only — see Q4 in the plan)"

# ── the relay answers at all ─────────────────────────────────────────────────
echo
log "solver: relay"
TOKENS="$(curl -fsS --max-time 10 "$RELAY/tokens" 2>/dev/null || true)"
if [[ -z "$TOKENS" ]]; then
  fail "GET /tokens did not answer — nothing below can be checked"
  exit 1
fi
if [[ "$TOKENS" == *'"tokens"'* ]]; then
  ok "GET /tokens answers: ${TOKENS}"
else
  fail "GET /tokens answered without a tokens field: ${TOKENS}"
  exit 1
fi

# ── the solver is CONNECTED, read from inside the relay ──────────────────────
# /state is loopback-only, so this is the one check that has to go through the container.
STATE="$(dc exec -T relay wget -q -O - -T 5 http://127.0.0.1:3000/state 2>/dev/null || true)"
if [[ -z "$STATE" ]]; then
  fail "GET /state (from inside the relay container) did not answer"
else
  CONNECTED="$(printf '%s' "$STATE" \
    | grep -oE '"connectedCount"[[:space:]]*:[[:space:]]*[0-9]+' \
    | grep -oE '[0-9]+$' | head -1)"
  if [[ -n "${CONNECTED:-}" ]] && (( CONNECTED >= 1 )); then
    ok "the relay reports ${CONNECTED} connected solver(s)"
  else
    fail "the relay reports connectedCount=${CONNECTED:-unreadable} — no solver is attached"
  fi
fi

# ── which colours this stack actually minted ─────────────────────────────────
# Read from the shared volume rather than hard-coded: colours derive from the deployed
# contract address, so they differ on every fresh stack.
echo
log "solver: the seeded pair"
MINTED="$(dc exec -T solver cat /srv/offerfiles-deploy/minted-tokens.json 2>/dev/null || true)"
[[ -n "$MINTED" ]] || MINTED="$(dc exec -T kernel cat /srv/offerfiles-deploy/minted-tokens.json 2>/dev/null || true)"
GIVE_TOKEN="${MAKER_OFFER_GIVE_TOKEN:-}"
WANT_TOKEN="${MAKER_OFFER_WANT_TOKEN:-}"
if [[ -z "$GIVE_TOKEN" || -z "$WANT_TOKEN" ]]; then
  if [[ -z "$MINTED" ]]; then
    fail "could not read minted-tokens.json from the shared volume, and no colours are configured"
    exit 1
  fi
  GIVE_TOKEN="$(printf '%s' "$MINTED" | grep -oE '"shieldedA"[[:space:]]*:[[:space:]]*"[0-9a-f]{64}"' | grep -oE '[0-9a-f]{64}' | head -1)"
  WANT_TOKEN="$(printf '%s' "$MINTED" | grep -oE '"shieldedB"[[:space:]]*:[[:space:]]*"[0-9a-f]{64}"' | grep -oE '[0-9a-f]{64}' | head -1)"
fi
if [[ ! "$GIVE_TOKEN" =~ ^[0-9a-f]{64}$ || ! "$WANT_TOKEN" =~ ^[0-9a-f]{64}$ ]]; then
  fail "could not resolve the two dev colours (give=${GIVE_TOKEN:-?} want=${WANT_TOKEN:-?})"
  exit 1
fi
# The maker GIVES the first colour and WANTS the second, so from the solver's side the
# directed pair is tokenIn=want, tokenOut=give. Getting this backwards is the single easiest
# mistake to make here, and it presents as a 503 that looks like a broken solver.
info "maker gives ${GIVE_AMOUNT} of ${GIVE_TOKEN:0:16}…"
info "maker wants ${WANT_AMOUNT} of ${WANT_TOKEN:0:16}…"
info "=> the solver's pair is tokenIn=${WANT_TOKEN:0:8}… tokenOut=${GIVE_TOKEN:0:8}…"

# ── the book, and the re-seed that keeps this section honest ─────────────────
# A LADDER IS DERIVED FROM THE BOOK, so with nothing live to quote an empty ladder is the
# correct answer rather than a broken one — which is why this section cannot simply assert a
# ladder and be done. What it must NOT do is treat "nothing to quote" as a pass: see the
# header. The book is therefore established FIRST, by re-seeding if necessary, and only then
# are the ladder and quote assertions run against a book that is known to hold the offer they
# describe.

# book_live_count — how many LIVE offers the kernel lists. `GET /v1/offers` returns only live
# ones, and every entry carries exactly one "offerId", so counting that key counts offers.
#
# THE `|| true` IS LOAD-BEARING, and its absence cost one gate run: on an EMPTY book `grep -o`
# matches nothing and exits 1, `pipefail` makes that the pipeline's status, the status becomes
# the function's, and `set -e` then kills the script inside `$( )` — silently, at exactly the
# moment this section exists to handle. `wc` still prints 0, which is the answer wanted.
book_live_count() {
  local body
  body="$(curl -fsS --max-time 10 "${KERNEL}/v1/offers?limit=100" 2>/dev/null || true)"
  printf '%s' "$body" | grep -o '"offerId"' | wc -l | tr -d '[:space:]' || true
}

# maker_marker — the maker-offer one-shot's durable marker, from its own volume.
#
# The one-shot has EXITED by the time verify runs, so `exec` cannot reach it; a throwaway
# `run` container mounting the same volume can. Since 00011 the marker carries the offer's
# full content hash, which is what lets the message below say CONSUMED or EXPIRED instead of
# "gone".
maker_marker() {
  dc run --rm --no-deps -T --entrypoint cat maker-offer /var/lib/maker-offer/.posted 2>/dev/null || true
}

# NOTE: `GET /v1/offers/<hash>/status` used to be read here on its own. It is not any more —
# maker_offer_fields() below reads the FULL offer, which carries the same status plus both
# legs, and FR-014 needs the legs. One round trip, one source of truth.

# wait_relay_advertises <budget_s> — both dev colours present in the relay's /tokens union.
#
# That union is built from what CONNECTED solvers advertise, and this solver advertises what
# it derived from the mirrored book — so one poll covers provisioning, book sync, derivation,
# the WS handshake and publication. It is a WAIT rather than a read because after a re-seed
# the solver needs a mirror cycle and a push cycle before it can be true.
wait_relay_advertises() {
  local budget="$1"
  local deadline=$(( SECONDS + budget ))
  local body
  while (( SECONDS < deadline )); do
    body="$(curl -fsS --max-time 10 "$RELAY/tokens" 2>/dev/null || true)"
    if [[ "$body" == *"$GIVE_TOKEN"* && "$body" == *"$WANT_TOKEN"* ]]; then
      TOKENS="$body"
      return 0
    fi
    sleep 5
  done
  TOKENS="${body:-$TOKENS}"
  return 1
}

# maker_offer_fields <64-hex hash> — the maker offer AS THE KERNEL HAS IT: its terminal
# status and both legs, flattened to key=value lines. Read from inside the solver container
# with `bun -e`, because `computed.gives[]` / `computed.wants[]` are NESTED and this host has
# neither jq nor bun.
#
# It never exits non-zero: a soft failure prints `fetch=…` for the caller to report, rather
# than ending the run through `set -e`.
#
# A QUOTED heredoc, for the reason given at STATUS_PROBE_JS further down.
read -r -d '' MAKER_PROBE_JS <<'MAKER_JS' || true
const hash = process.argv[1];
const r = await fetch("http://kernel:9999/v1/offers/" + hash,
                      { signal: AbortSignal.timeout(10000) }).catch(() => null);
if (!r) { console.log("fetch=unreachable"); process.exit(0); }
if (r.status === 404) { console.log("fetch=ok"); console.log("status=not_found"); process.exit(0); }
if (!r.ok) { console.log("fetch=http" + r.status); process.exit(0); }
const o = await r.json().catch(() => null);
if (!o || !o.computed) { console.log("fetch=unparseable"); process.exit(0); }
const g = (o.computed.gives ?? [])[0] ?? {};
const w = (o.computed.wants ?? [])[0] ?? {};
console.log([
  "fetch=ok",
  "status=" + o.computed.status,
  "giveToken=" + (g.token ?? "?"),
  "giveAmount=" + (g.amount ?? "?"),
  "wantToken=" + (w.token ?? "?"),
  "wantAmount=" + (w.amount ?? "?"),
].join(String.fromCharCode(10)));
MAKER_JS

maker_offer_fields() {
  # `|| true`: a solver that is down makes `dc exec` fail, and the caller must be able to
  # report "nothing" rather than have `set -e` end the run.
  dc exec -T solver bun -e "$MAKER_PROBE_JS" "$1" 2>/dev/null || true
}

# maker_hash — the seeded offer's full content hash, from the one-shot's own marker.
maker_hash() {
  # A marker written before 00011 PR B carries no hash; grep then exits 1 and, under
  # `pipefail` + `set -e`, would take the script with it.
  printf '%s' "$1" | grep -oE 'offerHash=[0-9a-f]{64}' | sed 's/^offerHash=//' | head -1 || true
}

# mfield <key> — one flat key=value line out of MAKER_FIELDS.
mfield() { printf '%s\n' "${MAKER_FIELDS:-}" | sed -n "s/^$1=//p" | head -1 || true; }

echo
log "solver: the book behind the ladder"
# ── WHY THIS KEYS ON THE MAKER OFFER AND NOT ON THE BOOK'S SIZE (00011 FR-014) ──
# Until PR C this section asked "is the book empty?" and re-seeded if it was. That question
# stopped being the right one the moment the `poster` profile existed: the poster keeps a
# spread of its OWN offers live, so the book is never empty on an `--all` stack — and a book
# with ten poster offers and NO maker offer would have sailed past the re-seed and then
# failed the exact-quote assertion for a reason the message did not name.
#
# So the question is now "is THE MAKER OFFER live?", asked by its own content hash from the
# one-shot's marker, and the quote expectation below is read from THAT OFFER rather than from
# .env defaults or from "the first offer in the book".
LIVE_OFFERS="$(book_live_count)"
MARKER="$(maker_marker)"
MAKER_HASH="$(maker_hash "$MARKER")"
MAKER_FIELDS=""
MAKER_STATUS=""
if [[ -n "${MAKER_HASH:-}" ]]; then
  MAKER_FIELDS="$(maker_offer_fields "$MAKER_HASH")"
  [[ "$MAKER_FIELDS" == *"fetch=ok"* ]] && MAKER_STATUS="$(mfield status)"
fi
info "the kernel book holds ${LIVE_OFFERS:-0} live offer(s) in total"

if [[ "$SEEDED" == "yes" && "${MAKER_STATUS:-}" != "live" ]]; then
  if [[ -z "${MAKER_HASH:-}" ]]; then
    warn "the maker-offer marker carries no offer hash, so the seeded offer cannot be identified"
    info "(a marker written before 00011 PR B, or a one-shot that never completed)"
  else
    warn "the seeded maker offer is not live — nothing of the maker's for the solver to quote"
    case "${MAKER_STATUS:-unreadable}" in
      consumed)
        info "the seeded offer ${MAKER_HASH:0:16}… is CONSUMED: its input nullifier was spent on"
        info "chain. A settled take does that — and so does an unrelated transfer from the"
        info "maker's own wallet that selected the coin the offer had reserved."
        ;;
      expired)
        info "the seeded offer ${MAKER_HASH:0:16}… is EXPIRED. On this chain an offer lives"
        info "min(ROOT_WINDOW_SECONDS, OFFER_TTL_SECONDS) = 1 h whatever TTL_MINUTES asked for."
        ;;
      not_found)
        info "the kernel has never heard of ${MAKER_HASH:0:16}… — a marker from another chain"
        info "(a volume that outlived a ./down.sh without -v)"
        ;;
      *)
        info "the seeded offer ${MAKER_HASH:0:16}… reports status '${MAKER_STATUS:-unreadable}'"
        ;;
    esac
  fi
  if (( ${LIVE_OFFERS:-0} > 0 )); then
    info "the book is NOT empty — ${LIVE_OFFERS} other offer(s) are live (the poster profile"
    info "keeps its own spread up). None of them is the offer this section's exact-quote"
    info "assertion describes, which is why the count alone cannot answer this."
  fi

  if [[ "${SOLVER_VERIFY_RESEED:-true}" != "true" ]]; then
    fail "no live maker offer and SOLVER_VERIFY_RESEED=false — the ladder and quote assertions"
    info "cannot be run without it, and skipping them would pass this section without testing"
    info "it. Re-run with SOLVER_VERIFY_RESEED=true, or './down.sh -v'."
    exit 1
  fi

  log "re-seeding the book (maker-offer with MAKER_OFFER_RESEED=true — proving, ~1-3 min)"
  if dc run --rm --no-deps -T -e MAKER_OFFER_RESEED=true maker-offer; then
    MARKER="$(maker_marker)"
    MAKER_HASH="$(maker_hash "$MARKER")"
    MAKER_FIELDS=""
    MAKER_STATUS=""
    if [[ -n "${MAKER_HASH:-}" ]]; then
      MAKER_FIELDS="$(maker_offer_fields "$MAKER_HASH")"
      [[ "$MAKER_FIELDS" == *"fetch=ok"* ]] && MAKER_STATUS="$(mfield status)"
    fi
    if [[ "${MAKER_STATUS:-}" != "live" ]]; then
      fail "the re-seed reported success but the new maker offer is '${MAKER_STATUS:-unreadable}'"
      exit 1
    fi
    LIVE_OFFERS="$(book_live_count)"
    ok "the book was re-seeded: maker offer ${MAKER_HASH:0:16}… is live (${LIVE_OFFERS} live offer(s) in total)"
  else
    fail "could not re-seed the book — the ladder and quote assertions below cannot be trusted"
    info "the maker-offer one-shot's own output is above; it names the cause."
    exit 1
  fi
  RESEEDED="yes"
else
  RESEEDED="no"
  if [[ "$SEEDED" == "yes" ]]; then
    ok "the seeded maker offer ${MAKER_HASH:0:16}… is live"
  fi
fi

# ── the expectation, read from the OFFER rather than from configuration ──────
# `quote(want) == give` holds because the derivation applies no fee and no margin: a rung IS
# the offer's own cumulative sums, and the relay returns a rung's output verbatim when
# amountIn lands exactly on it. WHOSE give and want, though, is the whole of FR-014 — with a
# poster on the same stack the book carries other offers, and reading the numbers off .env
# defaults would silently describe an offer that is not there.
if [[ "$SEEDED" == "yes" && "$MAKER_FIELDS" == *"fetch=ok"* ]]; then
  MAKER_GIVE_TOKEN="$(mfield giveToken)"
  MAKER_WANT_TOKEN="$(mfield wantToken)"
  MAKER_GIVE_AMOUNT="$(mfield giveAmount)"
  MAKER_WANT_AMOUNT="$(mfield wantAmount)"
  if [[ "$MAKER_GIVE_AMOUNT" =~ ^[0-9]+$ && "$MAKER_WANT_AMOUNT" =~ ^[0-9]+$ ]]; then
    if [[ "$MAKER_GIVE_AMOUNT" != "$GIVE_AMOUNT" || "$MAKER_WANT_AMOUNT" != "$WANT_AMOUNT" ]]; then
      info "the maker offer on the book gives ${MAKER_GIVE_AMOUNT} for ${MAKER_WANT_AMOUNT};"
      info "the configured defaults say ${GIVE_AMOUNT}/${WANT_AMOUNT}. THE OFFER WINS — the"
      info "assertions below follow the book, not .env."
    fi
    GIVE_AMOUNT="$MAKER_GIVE_AMOUNT"
    WANT_AMOUNT="$MAKER_WANT_AMOUNT"
    ok "the exact-quote expectation comes from offer ${MAKER_HASH:0:16}… itself: quote(${WANT_AMOUNT}) must be ${GIVE_AMOUNT}"
  else
    fail "could not read the maker offer's own legs from the kernel (${MAKER_FIELDS:-no output})"
  fi
  # The colours the ladder and refusal assertions use come from minted-tokens.json; the offer
  # is the second, independent witness. A mismatch means the marker points at somebody else's
  # offer, and every assertion below would be describing the wrong one.
  if [[ -n "${MAKER_GIVE_TOKEN:-}" && "$MAKER_GIVE_TOKEN" != "$GIVE_TOKEN" ]]; then
    fail "the seeded offer gives ${MAKER_GIVE_TOKEN:0:16}…, but this stack's minted give colour is ${GIVE_TOKEN:0:16}…"
  fi
  if [[ -n "${MAKER_WANT_TOKEN:-}" && "$MAKER_WANT_TOKEN" != "$WANT_TOKEN" ]]; then
    fail "the seeded offer wants ${MAKER_WANT_TOKEN:0:16}…, but this stack's minted want colour is ${WANT_TOKEN:0:16}…"
  fi
fi

if [[ "$SEEDED" == "yes" ]]; then
  if wait_relay_advertises "$LADDER_BUDGET_S"; then
    for colour in "$GIVE_TOKEN" "$WANT_TOKEN"; do
      ok "the relay advertises ${colour:0:16}…"
    done
    if [[ "$RESEEDED" == "yes" ]]; then
      info "(after the re-seed above)"
    fi
  else
    for colour in "$GIVE_TOKEN" "$WANT_TOKEN"; do
      if [[ "$TOKENS" == *"$colour"* ]]; then
        ok "the relay advertises ${colour:0:16}…"
      else
        fail "the relay does not advertise ${colour:0:16}… after ${LADDER_BUDGET_S}s — the solver published an EMPTY ladder"
      fi
    done
  fi
elif [[ "$SEEDED" == "no" ]]; then
  warn "SOLVER_PROVISION_ENABLED/MAKER_OFFER_ENABLED are not both true"
  info "the seeding one-shots were skipped, so an empty ladder is a legitimate state here"
  info "and the quote assertions below are skipped with it"
fi

# ── quoting ──────────────────────────────────────────────────────────────────
# The status code and the body are both needed on every call — a refusal is only meaningful
# together with its `error` field — so the body goes to a scratch file and the code to stdout.
QUOTE_BODY_FILE="$(mktemp)"
trap 'rm -f "$QUOTE_BODY_FILE"' EXIT

# quote <tokenIn> <tokenOut> <amountIn> — prints "<http status> <body>".
quote() {
  local body status
  body="$(printf '{"tokenIn":"%s","tokenOut":"%s","amountIn":"%s"}' "$1" "$2" "$3")"
  # NOT -f: a refusal is exactly what several of these calls are asserting, and --fail would
  # discard the body that says which refusal it is.
  status="$(curl -sS --max-time 20 -o "$QUOTE_BODY_FILE" -w '%{http_code}' \
              -H 'content-type: application/json' -d "$body" "$RELAY/quote" 2>/dev/null || true)"
  printf '%s %s\n' "${status:-000}" "$(tr -d '\n' < "$QUOTE_BODY_FILE" 2>/dev/null || true)"
}

if [[ "$SEEDED" == "yes" ]]; then
  echo
  log "solver: quote round trip"

  read -r STATUS BODY <<<"$(quote "$WANT_TOKEN" "$GIVE_TOKEN" "$WANT_AMOUNT")"
  if [[ "$STATUS" != "200" ]]; then
    fail "POST /quote at the ladder's own rung answered ${STATUS}: ${BODY}"
  else
    AMOUNT_OUT="$(printf '%s' "$BODY" | grep -oE '"amountOut"[[:space:]]*:[[:space:]]*"[0-9]+"' | grep -oE '[0-9]+' | head -1)"
    QUOTE_ID="$(printf '%s' "$BODY" | grep -oE '"quoteId"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"quoteId"[[:space:]]*:[[:space:]]*"//; s/"$//' | head -1)"
    if [[ "$AMOUNT_OUT" == "$GIVE_AMOUNT" ]]; then
      ok "quote(${WANT_AMOUNT}) = ${AMOUNT_OUT} — exactly the maker's whole offer"
    else
      fail "quote(${WANT_AMOUNT}) = ${AMOUNT_OUT:-unreadable}, expected exactly ${GIVE_AMOUNT}"
      info "the derivation applies no fee, so a rung IS the offer's sums. A different number"
      info "means either the book carries more offers than the seeded one (a better-priced"
      info "maker raises this) or the maker offer's amounts were changed in .env."
    fi
    if [[ -n "${QUOTE_ID:-}" ]]; then
      ok "the quote carries a routing quoteId (${QUOTE_ID:0:8}…)"
    else
      fail "the quote carries no quoteId — an intent could not be routed back to this solver"
    fi
  fi

  # Below the ladder's first rung. zswap offers are all-or-nothing, so the relay refuses
  # rather than pro-rating: an interpolation below the first rung has no chord to sit on.
  read -r STATUS BODY <<<"$(quote "$WANT_TOKEN" "$GIVE_TOKEN" 1)"
  if [[ "$STATUS" == "422" && "$BODY" == *'"unfulfillable"'* ]]; then
    ok "a size below the first rung is refused 422 unfulfillable"
  else
    fail "a size below the first rung answered ${STATUS}: ${BODY}"
  fi
fi

echo
log "solver: refusals"
# The REVERSE direction. One maker offer backs exactly one directed pair; the other direction
# has no levels at all, and 503 (transient — a solver may connect or replenish) is the honest
# answer. A 200 here would mean the solver is quoting a side it cannot fill.
read -r STATUS BODY <<<"$(quote "$GIVE_TOKEN" "$WANT_TOKEN" "$GIVE_AMOUNT")"
if [[ "$STATUS" == "503" && "$BODY" == *'"no_solver"'* ]]; then
  ok "the unbacked reverse direction is refused 503 no_solver"
else
  fail "the reverse direction answered ${STATUS}: ${BODY}"
fi

# An entirely unpriced colour. NIGHT's all-zero id is guaranteed to exist as a token and
# guaranteed not to be on any ladder here.
NIGHT_COLOUR="0000000000000000000000000000000000000000000000000000000000000000"
read -r STATUS BODY <<<"$(quote "$NIGHT_COLOUR" "$GIVE_TOKEN" 1000)"
if [[ "$STATUS" == "503" && "$BODY" == *'"no_solver"'* ]]; then
  ok "an unpriced colour is refused 503 no_solver"
else
  fail "an unpriced colour answered ${STATUS}: ${BODY}"
fi

read -r STATUS BODY <<<"$(quote "$GIVE_TOKEN" "$GIVE_TOKEN" 1000)"
if [[ "$STATUS" == "400" ]]; then
  ok "tokenIn == tokenOut is refused 400"
else
  fail "tokenIn == tokenOut answered ${STATUS}: ${BODY}"
fi

# ── the solver's own durable state ───────────────────────────────────────────
echo
log "solver: journal"
if dc exec -T solver test -f /var/lib/cow-solver/operations.sqlite >/dev/null 2>&1; then
  ok "the wallet-operation journal exists on its volume"
else
  fail "no journal at /var/lib/cow-solver/operations.sqlite — the solver opens it fail-closed"
fi

# ── the read-only status listener (kernel PR #58) ────────────────────────────
# INSIDE the network, because the port is deliberately not published (00011 Q4): the monitor
# is its reader, and /status/* carries the solver's entire internal state.
#
# BOTH halves matter. A 200 with the bearer alone would not prove the listener is gated, and a
# 401 without it alone would not prove it serves anything. The bearer is read from the
# container's OWN environment rather than from this host's, so the assertion also proves the
# two sides are configured from one value.
if service_present solver; then
  echo
  log "solver: status listener (:9100, network-internal)"

  # The probe script, as a QUOTED heredoc rather than an inline single-quoted argument: the
  # `'"'"'` escape needed to embed a JS string inside a shell single-quoted word is unreadable
  # and shellcheck cannot parse it either.
  read -r -d '' STATUS_PROBE_JS <<'PROBE_JS' || true
const [path, mode] = [process.argv[1], process.argv[2]];
const headers = mode === "with"
  ? { authorization: "Bearer " + (process.env.SOLVER_STATUS_AUTH_TOKEN ?? "") }
  : {};
const r = await fetch("http://127.0.0.1:9100" + path,
                      { headers, signal: AbortSignal.timeout(8000) }).catch(() => null);
console.log(r ? String(r.status) : "000");
PROBE_JS

  # status_code <path> <with|without> — the HTTP status of one request to the listener.
  # `bun -e`, not curl: the oven/bun base image ships neither curl nor wget.
  status_code() {
    # `|| true`: a solver that is down makes `dc exec` fail, and the caller must be able to
    # report "nothing" rather than have `set -e` end the run.
    dc exec -T solver bun -e "$STATUS_PROBE_JS" "$1" "$2" 2>/dev/null | tr -d '[:space:]' || true
  }

  # /health is OPEN by design — a container healthcheck must not need the secret — and carries
  # nothing internal (status, ready, mode, contractVersion).
  CODE="$(status_code /health without)"
  if [[ "$CODE" == "200" ]]; then
    ok "GET /health on the listener answers 200 without a bearer (open by design)"
  else
    fail "GET /health on the listener answered ${CODE:-nothing} — is SOLVER_STATUS_PORT set?"
  fi

  CODE="$(status_code /status/snapshot with)"
  if [[ "$CODE" == "200" ]]; then
    ok "GET /status/snapshot WITH the bearer answers 200"
  else
    fail "GET /status/snapshot with the bearer answered ${CODE:-nothing}"
  fi

  CODE="$(status_code /status/snapshot without)"
  if [[ "$CODE" == "401" || "$CODE" == "403" ]]; then
    ok "GET /status/snapshot WITHOUT the bearer is refused ${CODE}"
  else
    fail "GET /status/snapshot without a bearer answered ${CODE:-nothing} — the listener is OPEN"
  fi
fi

# ── the monitor (solver-frontend) ────────────────────────────────────────────
if service_present solver-frontend; then
  echo
  log "solver: monitor"

  # The snapshot probe, flattened to `key=value` lines this script can compare as exact
  # strings. Read from INSIDE the container for the same reason /state is: this host has no jq
  # and no bun, and these verify scripts take no dependency a stock macOS box lacks. A section
  # the aggregator could not fill arrives as `{error: ...}` rather than as data, and `sec()`
  # turns that into "absent" so it is reported rather than mis-read as a zero.
  #
  # A QUOTED heredoc, for the reason given at STATUS_PROBE_JS above.
  read -r -d '' MONITOR_PROBE_JS <<'MONITOR_JS' || true
const r = await fetch("http://127.0.0.1:8080/api/snapshot",
                      { signal: AbortSignal.timeout(8000) }).catch(() => null);
if (!r || !r.ok) { console.log("fetch=fail"); process.exit(0); }
const s = await r.json().catch(() => null);
if (!s) { console.log("fetch=unparseable"); process.exit(0); }
const sec = (v) => (v && typeof v === "object" && "error" in v ? null : v);
const solver = s.solver ?? {};
const snap = solver.snapshot ?? null;
const relay = snap ? sec(snap.relay) : null;
const ladder = snap ? sec(snap.ladder) : null;
const listener = snap ? sec(snap.listener) : null;
const tokens = sec(s.relay ? s.relay.tokens : null);
const book = sec(s.kernel ? s.kernel.book : null);
console.log([
  "fetch=ok",
  "monitorContractVersion=" + (s.monitor ? s.monitor.contractVersion : "?"),
  "solverState=" + (solver.state ?? "?"),
  "solverReachable=" + (solver.reachable === true),
  "solverTransport=" + (solver.transport ?? "none"),
  "solverContractVersion=" + (solver.contractVersion ?? "?"),
  "relayConnected=" + (relay && relay.stats ? relay.stats.connected === true : false),
  "ladderState=" + (ladder ? ladder.state : "?"),
  "ladderPairs=" + (ladder && ladder.last ? ladder.last.pairs : 0),
  "ladderRungs=" + (ladder && ladder.last ? ladder.last.rungs : 0),
  "ladderWithheld=" + (ladder && ladder.last ? (ladder.last.withheld ?? "none") : "?"),
  "listenerPort=" + (listener ? listener.port : "?"),
  "relayTokens=" + (Array.isArray(tokens) ? tokens.length : -1),
  "kernelBook=" + (book ? book.count : -1),
].join(String.fromCharCode(10)));
MONITOR_JS

  monitor_fields() {
    dc exec -T solver-frontend bun -e "$MONITOR_PROBE_JS" 2>/dev/null
  }

  # 1. /health on the PUBLISHED host port. Three keys, no internal data — and `state` appears
  #    exactly once in that body, so an exact-string grep is unambiguous here.
  HEALTH_FILE="$(mktemp)"
  HEALTH_CODE="$(curl -sS --max-time 10 -o "$HEALTH_FILE" -w '%{http_code}' "$MONITOR/health" 2>/dev/null || true)"
  HEALTH_BODY="$(tr -d '\n' < "$HEALTH_FILE" 2>/dev/null || true)"
  rm -f "$HEALTH_FILE"
  if [[ "$HEALTH_CODE" == "200" && "$HEALTH_BODY" == *'"status":"ok"'* ]]; then
    ok "GET ${MONITOR}/health answers 200 with status ok"
  else
    fail "GET ${MONITOR}/health answered ${HEALTH_CODE:-nothing}: ${HEALTH_BODY:-empty}"
  fi

  # 2. The aggregate the page renders. This is a WAIT, not a read: spec SC-004 gives the
  #    monitor three minutes from the solver turning healthy to report a relay-connected
  #    solver with a non-empty published ladder, and `up.sh` may have returned seconds ago.
  MON_START=$SECONDS
  MON_DEADLINE=$(( SECONDS + MONITOR_BUDGET_S ))
  FIELDS=""
  while :; do
    FIELDS="$(monitor_fields || true)"
    if [[ "$FIELDS" == *"solverReachable=true"* && "$FIELDS" == *"relayConnected=true"* ]]; then
      # A ladder is only expected where the book was seeded; with the one-shots off, waiting
      # for rungs would burn the whole budget proving nothing.
      if [[ "$SEEDED" != "yes" ]] || [[ "$FIELDS" != *"ladderRungs=0"* ]]; then
        break
      fi
    fi
    (( SECONDS < MON_DEADLINE )) || break
    sleep 5
  done
  MON_ELAPSED=$(( SECONDS - MON_START ))

  if [[ "$FIELDS" != *"fetch=ok"* ]]; then
    fail "GET /api/snapshot did not return a snapshot (${FIELDS:-no output})"
  else
    ok "GET ${MONITOR}/api/snapshot returns the aggregated snapshot"
    info "settled after ${MON_ELAPSED}s (budget ${MONITOR_BUDGET_S}s)"
    printf '%s\n' "$FIELDS" | while IFS= read -r field; do info "  ${field}"; done

    # The solver half. `reachable` is the only state that can be reached by AUTHENTICATING
    # against the bearer-gated listener, so this one field proves the whole monitor->solver
    # wire — URL, bearer and contract version — from outside both processes.
    if [[ "$FIELDS" == *"solverState=reachable"* && "$FIELDS" == *"solverReachable=true"* ]]; then
      ok "the monitor reports the solver's status stream REACHABLE"
    else
      fail "the monitor does not report the solver reachable — check SOLVER_STATUS_AUTH_TOKEN on both sides"
    fi
    # A snapshot from a solver on a different status contract version would be rendered
    # wrongly rather than not at all, so the two versions are compared.
    if [[ "$FIELDS" == *"solverContractVersion=1"* && "$FIELDS" == *"monitorContractVersion=1"* ]]; then
      ok "solver and monitor agree on status contract version 1"
    else
      fail "status contract version mismatch between the solver and its monitor"
    fi
    if [[ "$FIELDS" == *"relayConnected=true"* ]]; then
      ok "the snapshot reports the solver's relay socket CONNECTED"
    else
      fail "the snapshot reports the solver's relay socket down"
    fi
    if [[ "$SEEDED" == "yes" ]]; then
      if [[ "$FIELDS" == *"ladderState=derived"* && "$FIELDS" != *"ladderRungs=0"* ]]; then
        ok "the snapshot carries a NON-EMPTY published ladder"
      else
        fail "the snapshot carries no published ladder rungs after ${MON_ELAPSED}s"
      fi
      # `withheld` non-null is the fail-closed EMPTY publication (`cache-not-current`), which
      # the page words differently from "no liquidity" and this script must not confuse either.
      if [[ "$FIELDS" == *"ladderWithheld=none"* ]]; then
        ok "the ladder is a real publication, not a fail-closed withdrawal"
      else
        fail "the last ladder push was WITHHELD — the solver refused to quote from its cache"
      fi
      # The relay panel: the same union /tokens serves, read through the monitor.
      if [[ "$FIELDS" == *"relayTokens=2"* ]]; then
        ok "the monitor's relay panel lists both advertised colours"
      elif [[ "$FIELDS" == *"relayTokens=-1"* || "$FIELDS" == *"relayTokens=0"* ]]; then
        fail "the monitor's relay panel lists no tokens"
      else
        ok "the monitor's relay panel lists the advertised colours"
      fi
    fi
    # The kernel panel is the half that must keep working with the solver DOWN, so it is
    # asserted independently of everything above.
    if [[ "$FIELDS" == *"kernelBook=-1"* ]]; then
      fail "the monitor could not read the kernel's book — its always-on source"
    else
      ok "the monitor reads the kernel's book directly (it renders with the solver down)"
    fi
  fi

  # 3. The SSE feed. One frame on connect is the contract; `--max-time` bounds the stream,
  #    and curl exits 28 on that timeout, which is success here rather than failure.
  STREAM="$(curl -sSN --max-time 10 -H 'accept: text/event-stream' "$MONITOR/api/stream" 2>/dev/null | head -c 4000 || true)"
  if [[ "$STREAM" == *"data:"* ]]; then
    ok "GET /api/stream delivers a first SSE data frame within 10s"
  else
    fail "GET /api/stream delivered no data frame in 10s"
  fi
fi

# ── the browser surface ──────────────────────────────────────────────────────
if service_present intents-ui; then
  echo
  log "solver: intents UI"
  PAGE="$(curl -fsS --max-time 10 "$UI/" 2>/dev/null || true)"
  if [[ "$PAGE" == *'id="config"'* ]]; then
    ok "the page is served with its injected runtime configuration"
  else
    fail "GET / did not return the app's index.html with its config block"
  fi
  # The browser-network property, asserted rather than reasoned about: the page reaches the
  # relay ONLY through this same-origin prefix, and the UI container's nginx strips it before
  # proxying. If this returns the same tokens the relay does, a browser can trade here.
  # Read BOTH sides now rather than comparing against the token list this script started
  # with: the union changes whenever the solver republishes, and a stale left-hand side would
  # make this assertion flap for a reason that has nothing to do with the UI's edge.
  UI_TOKENS="$(curl -fsS --max-time 10 "$UI/api/v1/tokens" 2>/dev/null || true)"
  RELAY_TOKENS_NOW="$(curl -fsS --max-time 10 "$RELAY/tokens" 2>/dev/null || true)"
  if [[ -n "$UI_TOKENS" && "$UI_TOKENS" == "$RELAY_TOKENS_NOW" ]]; then
    ok "GET /api/v1/tokens through the UI's own edge matches the relay"
  else
    fail "the UI's /api/v1 edge does not mirror the relay: ${UI_TOKENS:-no answer}"
  fi
  # No compose-internal hostname may ever reach a browser. The page is the one artefact that
  # could carry one, so it is grepped rather than trusted.
  if [[ "$PAGE" == *"http://relay:"* || "$PAGE" == *"ws://relay:"* ]]; then
    fail "the served page names the compose-internal host 'relay' — a browser cannot resolve it"
  else
    ok "the served page names no compose-internal hostname"
  fi
fi

# ── the container healthcheck itself (00015 PR B; issues/00013) ──────────────
#
# THE HEALTHCHECK IS A THING THAT CAN BE WRONG, so it is checked rather than trusted. Since
# 00015 it probes the solver's own `GET /health` and passes iff the answer is 200 with
# `ready: true`; before that it probed the RELAY's /tokens and called the solver unhealthy
# whenever that list was empty while the kernel book was not — a state the solver enters BY
# DESIGN on every fail-closed empty ladder, measured at ~1 flip per minute on an idle stack.
#
# So the assertion that matters is not "is it healthy now" but "does it STAY healthy while the
# book churns": zero exit-1 samples in the container's health log. Docker keeps the last 5
# probe results there, at 10 s apart, i.e. a ~50 s window — so the log is SAMPLED repeatedly and
# every exit code seen is accumulated, rather than read once at the end where 4 of 5 flips would
# already have aged out.
#
# It runs LAST on purpose: by the time this section reaches here, the book, ladder, quote,
# refusal, journal and listener blocks have all run — minutes of real churn, including a
# re-seeded maker offer — which is exactly the traffic that used to make the old probe flip.
if service_present solver; then
  echo
  log "solver: the container healthcheck (does it stay green while the book churns?)"

  SOLVER_CID="$(docker ps -aq \
    --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" \
    --filter "label=com.docker.compose.service=solver" 2>/dev/null | head -1 || true)"

  # health_field <go-template> — one field of .State.Health, or the empty string. `|| true`
  # everywhere: a container that has gone away must be reportable, not fatal under `set -e`.
  health_field() {
    [[ -n "$SOLVER_CID" ]] || { printf ''; return 0; }
    docker inspect -f "$1" "$SOLVER_CID" 2>/dev/null || true
  }
  # The exit codes of the probes docker still remembers, newest last, one per line. An empty
  # answer (no health block at all) prints nothing rather than failing.
  health_exit_codes() {
    health_field '{{if .State.Health}}{{range .State.Health.Log}}{{.ExitCode}}{{"\n"}}{{end}}{{end}}' \
      | grep -E '^[0-9]+$' || true
  }

  if [[ -z "$SOLVER_CID" ]]; then
    fail "no solver container for project '${COMPOSE_PROJECT_NAME}' — this section should not have run"
  else
    H_STATUS="$(health_field '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')"
    H_STREAK="$(health_field '{{if .State.Health}}{{.State.Health.FailingStreak}}{{else}}-1{{end}}')"

    if [[ "$H_STATUS" == "healthy" ]]; then
      ok "the solver container reports Health.Status=healthy"
    else
      fail "the solver container reports Health.Status=${H_STATUS:-unreadable} — its /health says ready is not true, or the listener is not bound (SOLVER_STATUS_PORT)"
    fi
    if [[ "$H_STREAK" == "0" ]]; then
      ok "Health.FailingStreak is 0"
    else
      fail "Health.FailingStreak is ${H_STREAK:-unreadable}, expected 0"
    fi

    # ── the flap window ──────────────────────────────────────────────────────
    # SOLVER_HEALTH_SAMPLE_S seconds of sampling every 10 s (one docker inspect per sample,
    # which costs nothing), accumulating every exit code the log has shown. 200 s by default:
    # comfortably longer than the ~50 s the log itself retains, so the samples overlap and
    # nothing can slip between them, and long enough that the old check — which flipped about
    # once a minute — would have been caught several times over.
    SOLVER_HEALTH_SAMPLE_S="${SOLVER_HEALTH_SAMPLE_S:-200}"
    info "sampling Health.Log every 10 s for ${SOLVER_HEALTH_SAMPLE_S}s (the log holds the last 5 probes, so the windows overlap)"
    HEALTH_SAMPLES=0
    HEALTH_BAD=0
    HEALTH_DEADLINE=$(( SECONDS + SOLVER_HEALTH_SAMPLE_S ))
    while (( SECONDS < HEALTH_DEADLINE )); do
      # `|| true` on the count: `grep -c` exits 1 when it counts zero, which is the ANSWER we
      # want most of the time.
      CODES="$(health_exit_codes)"
      BAD_NOW="$(printf '%s\n' "$CODES" | grep -c -v '^0$' || true)"
      # printf of an empty string still emits one (empty) line, which `grep -v '^0$'` counts.
      [[ -n "$CODES" ]] || BAD_NOW=0
      if (( BAD_NOW > HEALTH_BAD )); then HEALTH_BAD="$BAD_NOW"; fi
      HEALTH_SAMPLES=$(( HEALTH_SAMPLES + 1 ))
      sleep 10
    done
    FINAL_CODES="$(health_exit_codes | tr '\n' ' ')"
    if [[ "$HEALTH_BAD" == "0" ]]; then
      ok "${HEALTH_SAMPLES} samples over ${SOLVER_HEALTH_SAMPLE_S}s: every remembered probe exited 0 (last window: ${FINAL_CODES:-none})"
    else
      fail "${HEALTH_SAMPLES} samples over ${SOLVER_HEALTH_SAMPLE_S}s: up to ${HEALTH_BAD} of the 5 remembered probes had exited non-zero (last window: ${FINAL_CODES:-none}).
          The healthcheck is flapping. Since 00015 it asks the solver's own /health for \`ready\`, which is a
          startup latch — a flap here means the listener is dropping requests or the solver is restarting."
    fi

    # ── the transition, opt-in because it disturbs the stack ─────────────────
    # SOLVER_VERIFY_HEALTH_TRANSITION=1 only. Two halves, and the SECOND one is the surprise
    # worth writing down (00015 question Q5):
    #
    #   1. stopping the RELAY does NOT change anything. `ready` is `solverIsReady` in
    #      packages/solver/src/run.ts — a one-way latch (first book sync + backend projection
    #      current + inventory read) cleared only by the solver's own stop(). The relay socket
    #      is not part of it. This half MEASURES that rather than asserting a transition the
    #      code cannot make, so a future re-pin where upstream does clear the latch shows up
    #      here as a changed measurement instead of a silent pass.
    #   2. stopping the SOLVER is the transition this check actually gates on: the listener
    #      goes with the process, the probe fails, the container turns unhealthy — and comes
    #      back healthy after `start`, once startup has re-latched `ready`. Both times recorded.
    if [[ "${SOLVER_VERIFY_HEALTH_TRANSITION:-}" == "1" || "${SOLVER_VERIFY_HEALTH_TRANSITION:-}" == "true" ]]; then
      echo
      log "solver: health transitions (SOLVER_VERIFY_HEALTH_TRANSITION is set — this stops and starts containers)"

      if service_present relay; then
        info "stopping the relay for 60 s and watching the solver's health"
        dc stop relay >/dev/null 2>&1 || true
        RELAY_OBS_DEADLINE=$(( SECONDS + 60 ))
        RELAY_SAW_UNHEALTHY=0
        while (( SECONDS < RELAY_OBS_DEADLINE )); do
          [[ "$(health_field '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')" == "healthy" ]] || RELAY_SAW_UNHEALTHY=1
          sleep 10
        done
        dc start relay >/dev/null 2>&1 || true
        if (( RELAY_SAW_UNHEALTHY )); then
          info "MEASURED: the solver left 'healthy' while the relay was down — upstream's \`ready\` now tracks the relay socket; update the fragment comment and 00015 Q5"
        else
          ok "MEASURED: the solver stayed healthy for 60 s with the relay STOPPED — \`ready\` is a startup latch and does not track the relay socket (00015 Q5); the relay/ladder assertions above are where that guarantee lives"
        fi
        dc start relay >/dev/null 2>&1 || true
      fi

      # ── DOWN: what this half does and does not measure ────────────────────
      # Docker marks a STOPPED container `unhealthy` itself, the moment it exits (measured on
      # this daemon with a throwaway container). So the number below is the stop's own latency,
      # not a probe-failure latency — what it proves is that the container leaves `healthy`
      # when the solver goes away, i.e. that nothing here can report a dead solver as fine.
      # The genuine probe-in-the-red measurement is the UP half, below.
      info "stopping the solver and waiting for the container to leave 'healthy'"
      T0=$SECONDS
      dc stop solver >/dev/null 2>&1 || true
      DOWN_SECS=""
      DOWN_DEADLINE=$(( SECONDS + 180 ))
      while (( SECONDS < DOWN_DEADLINE )); do
        if [[ "$(health_field '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')" != "healthy" ]]; then
          DOWN_SECS=$(( SECONDS - T0 )); break
        fi
        sleep 2
      done
      if [[ -n "$DOWN_SECS" ]]; then
        ok "the solver left 'healthy' ${DOWN_SECS}s after \`docker compose stop solver\` (docker marks a stopped container unhealthy itself) — health=$(health_field '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')"
      else
        fail "the solver container was still 'healthy' 180 s after it was stopped — this healthcheck cannot go red"
      fi

      # ── UP: the real red-then-green measurement, and Q3's number ──────────
      # The listener binds BEFORE the wallet (upstream, on purpose), so from the moment the
      # container is up its /health answers 200 with `ready: false` — every probe in that
      # window is a genuine exit 1 against a live listener, which is exactly the red path this
      # check must have. The time to `healthy` is what `start_period: 180s` has to cover, so it
      # is reported whether or not it is inside the window.
      info "starting the solver again and waiting for ready:true and healthy"
      T0=$SECONDS
      dc start solver >/dev/null 2>&1 || true
      UP_SECS=""
      UP_DEADLINE=$(( SECONDS + 600 ))
      while (( SECONDS < UP_DEADLINE )); do
        if [[ "$(health_field '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')" == "healthy" ]]; then
          UP_SECS=$(( SECONDS - T0 )); break
        fi
        sleep 5
      done
      if [[ -n "$UP_SECS" ]]; then
        if (( UP_SECS <= 180 )); then
          ok "the solver was healthy again ${UP_SECS}s after \`docker compose start solver\` — inside the 180 s start_period"
        else
          warn "the solver took ${UP_SECS}s to become healthy again, LONGER than start_period (180 s). On a host this slow the container would be marked unhealthy during a cold start; consider raising start_period in compose/solver.yml."
        fi
      else
        fail "the solver did not return to 'healthy' within 600 s of being started"
      fi
    fi
  fi
fi

echo
if (( FAILURES == 0 )); then
  ok "solver: all assertions passed"
  exit 0
fi
err "solver: ${FAILURES} assertion(s) failed"
exit 1
