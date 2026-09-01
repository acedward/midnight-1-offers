#!/usr/bin/env bash
# maker-offer — seed the kernel's order book with ONE real, settle-able offer. ONE-SHOT.
#
# The solver's ladder is derived from the MIRRORED OFFER-FILES BOOK, not from its ladder
# config file. An empty book therefore means an empty ladder no matter how well funded the
# solver is — the second half of the silent trap described in entrypoint-solver-provision.sh.
#
# So that a plain `./up.sh --with offerfiles --with solver` produces the stack this profile
# claims to produce — a solver quoting a real pair at the relay — this one-shot posts a
# single genuine offer. It is a DEVNET seeding step, exactly like the deploy one-shot's mint;
# set MAKER_OFFER_ENABLED=false for a deployment that sources its book from real makers (the
# SPA, or a person), and nothing else changes.
#
# It posts a REAL PROVEN OFFER, not a database row. The kernel's own `seed:market` writes
# rows whose blob is a placeholder and which its own header calls NOT settle-able; a ladder
# built from those would let this profile's smoke test pass over a stack that can never fill
# anything.
#
# WHICH DIRECTION THIS CREATES. An offer that GIVES `GIVE_AMOUNT` of `GIVE_TOKEN` and WANTS
# `WANT_AMOUNT` of `WANT_TOKEN` is filled by a taker who pays the WANT and receives the GIVE.
# Read from the solver's side that is tokenIn = WANT_TOKEN, tokenOut = GIVE_TOKEN — which is
# the pair scripts/verify-solver.sh quotes, and the reason solver-provision mints BOTH
# colours (tokenIn for the fee-sizing mirror, tokenOut for interpolation residuals).

# Consumed by log() in the sourced prelude, which shellcheck cannot see from here.
# shellcheck disable=SC2034
ROLE=maker-offer
# shellcheck source=images/offerfiles-kernel/entrypoint-common.sh
. /usr/local/lib/offerfiles/entrypoint-common.sh

# "" IS NOT "unset", and for the AMOUNTS it is silently destructive: the posting script reads
# them as `BigInt(process.env.GIVE_AMOUNT ?? "500000")`, and `BigInt("")` is 0n rather than an
# error — so a knob merely left blank in .env posts an offer that gives NOTHING. `TTL_MINUTES`
# is the same shape through `Number("")`, i.e. an offer that expires the moment it is posted.
# The two colours are already tolerant of "" (they fall back to the minted-colours file), and
# are unset here only so all five behave the same way.
unset_if_empty GIVE_TOKEN WANT_TOKEN GIVE_AMOUNT WANT_AMOUNT TTL_MINUTES

require_env ZSWAP_API MIDNIGHT_NETWORK_ID

MARKER_DIR="${MAKER_OFFER_MARKER_DIR:-/var/lib/maker-offer}"
MARKER="${MARKER_DIR}/.posted"
mkdir -p "${MARKER_DIR}"

if [ "${MAKER_OFFER_ENABLED:-true}" != "true" ]; then
  log "MAKER_OFFER_ENABLED=${MAKER_OFFER_ENABLED:-} — not seeding the order book"
  log "NOTE: with an empty book the solver publishes an EMPTY ladder and the relay quotes"
  log "NOTE: nothing, while every service still reports healthy."
  exit 0
fi

# Idempotent for the same reason as the other one-shots: a restart must not re-prove and
# re-post an offer (tens of seconds of proving) or silently deepen the book on every bounce.
if [ -f "${MARKER}" ]; then
  log "JOIN: ${MARKER} exists — a maker offer was already posted against this chain"
  log "$(cat "${MARKER}")"
  exit 0
fi

adopt_contract_address

wait_http "${ZSWAP_API}/v1/health" "kernel API" "${KERNEL_WAIT_TIMEOUT_S:-600}" \
  || die "the kernel API never answered — nowhere to post an offer"

cd "${REPO_ROOT}" || die "no ${REPO_ROOT}"
log "posting one maker offer into the kernel book (proving — this takes a while)"
if bun run deploy/scripts/post-maker-offer.ts; then
  date -u +%Y-%m-%dT%H:%M:%SZ > "${MARKER}"
  log "maker offer live; marker written to ${MARKER}"
  exit 0
fi

# Fail loudly: a book with no offers is indistinguishable, from the outside, from a solver
# that is working perfectly and simply has nothing to quote.
log "ERROR: could not post the maker offer — the solver will publish an EMPTY ladder"
log "ERROR: (nothing to quote). The cause is in the log above."
exit 1
