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
#                     quote(WANT_AMOUNT) == GIVE_AMOUNT, to the unit.
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
#
# WHAT IT DELIBERATELY DOES NOT PROVE. The UI's swap flow needs a Midnight WALLET EXTENSION
# to sign an intent (`window.midnight`, the dapp-connector API), which no script on this host
# can provide. The quote half of that flow is asserted above; the take half is a manual step,
# and the scripted settlement proof is the P5 driver, not this script.
#
# ALSO NOT HERE: settlement itself. This script must stay side-effect-free — it is run
# repeatedly, including immediately after `up.sh` — and a take CONSUMES the seeded offer,
# which would make the very next run fail with an empty book.
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
info "intents UI ${UI}"

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

# A LADDER IS DERIVED FROM THE BOOK, so an empty book means an empty ladder is correct rather
# than broken — and an empty book is exactly what a successful demo LEAVES BEHIND, because a
# settled take consumes the offer it filled. Asserting a ladder against a consumed book would
# turn "the stack did its job" into a red verify run, so the book is checked first and the
# assertions that depend on it are skipped, loudly, when there is nothing to quote.
BOOK="$(curl -fsS --max-time 10 "http://${BIND}:${KERNEL_HOST_PORT:-9999}/v1/offers?limit=5" 2>/dev/null || true)"
if [[ "$SEEDED" == "yes" && "$BOOK" == '{"offers":[]'* ]]; then
  SEEDED="consumed"
  warn "the kernel book holds no live offer, so there is nothing for the solver to quote"
  info "that is the state a SETTLED take leaves behind — the ladder and quote assertions are"
  info "skipped rather than failed. './down.sh -v' for a fresh book, or post another offer."
fi

if [[ "$SEEDED" == "yes" ]]; then
  for colour in "$GIVE_TOKEN" "$WANT_TOKEN"; do
    if [[ "$TOKENS" == *"$colour"* ]]; then
      ok "the relay advertises ${colour:0:16}…"
    else
      fail "the relay does not advertise ${colour:0:16}… — the solver published an EMPTY ladder"
    fi
  done
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
  UI_TOKENS="$(curl -fsS --max-time 10 "$UI/api/v1/tokens" 2>/dev/null || true)"
  if [[ "$UI_TOKENS" == "$TOKENS" ]]; then
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

echo
if (( FAILURES == 0 )); then
  ok "solver: all assertions passed"
  exit 0
fi
err "solver: ${FAILURES} assertion(s) failed"
exit 1
