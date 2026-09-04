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

# offer_hash_for_prefix <12-hex prefix> — the FULL offer hash of a live book entry.
#
# post-maker-offer.ts prints `offer <first 12 hex>… is LIVE` and nothing longer, so the full
# content hash has to be recovered from the book. It is worth recovering: the marker is the
# only durable record connecting THIS chain's seeded offer to a hash, and ./verify.sh reads it
# to say whether a vanished offer was CONSUMED or EXPIRED instead of guessing (00011 B.5b),
# rather than assuming the book holds exactly one offer.
#
# `bun -e`, not curl: the oven/bun base image ships neither curl nor wget (see wait-for.sh).
offer_hash_for_prefix() {
  bun -e '
    const [api, prefix] = [process.argv[1], process.argv[2]];
    const r = await fetch(api + "/v1/offers?limit=100").catch(() => null);
    if (!r || !r.ok) process.exit(1);
    const body = await r.json().catch(() => ({}));
    const hit = (body.offers ?? []).find((o) => String(o.offerId ?? "").startsWith(prefix));
    if (!hit) process.exit(1);
    console.log(hit.offerId);
  ' "${ZSWAP_API}" "$1" 2>/dev/null
}

if [ "${MAKER_OFFER_ENABLED:-true}" != "true" ]; then
  log "MAKER_OFFER_ENABLED=${MAKER_OFFER_ENABLED:-} — not seeding the order book"
  log "NOTE: with an empty book the solver publishes an EMPTY ladder and the relay quotes"
  log "NOTE: nothing, while every service still reports healthy."
  exit 0
fi

# Idempotent for the same reason as the other one-shots: a restart must not re-prove and
# re-post an offer (tens of seconds of proving) or silently deepen the book on every bounce.
#
# MAKER_OFFER_RESEED IS THE DELIBERATE EXCEPTION (00011 B.5b). The seeded offer does not live
# forever: an `undeployed` chain expires offers at min(ROOT_WINDOW_SECONDS, OFFER_TTL_SECONDS)
# = 1 h whatever TTL_MINUTES asks for, and the kernel marks an offer CONSUMED the moment any
# on-chain transaction spends its input nullifier — a settled take, but equally an unrelated
# transfer from the maker's own wallet that happens to select the reserved coin. So a long
# stack legitimately ends up with an empty book and a marker that says "already seeded", and
# ./verify.sh used to WARN-skip its ladder and quote assertions there. It now re-runs this
# one-shot with MAKER_OFFER_RESEED=true instead, which is the only sanctioned way past the
# marker: an operator restart still JOINs, exactly as before.
if [ -f "${MARKER}" ] && [ "${MAKER_OFFER_RESEED:-false}" != "true" ]; then
  log "JOIN: ${MARKER} exists — a maker offer was already posted against this chain"
  log "$(cat "${MARKER}")"
  log "NOTE: set MAKER_OFFER_RESEED=true to post another one (./verify.sh does this itself"
  log "NOTE: when the book has no live maker offer left)."
  exit 0
fi

if [ -f "${MARKER}" ]; then
  log "MAKER_OFFER_RESEED=true — re-seeding the book even though ${MARKER} exists"
  log "previous marker: $(tr '\n' ' ' < "${MARKER}")"
fi

adopt_contract_address

# ── the genesis-1 facade mutex (00011 Q7) ────────────────────────────────────
# MAKER_SEED defaults to the GENESIS seed, because the deploy one-shot's mint credited
# exactly that wallet — it is the only one holding a test token to give away. So this
# one-shot is the third genesis-1 facade in the stack, beside `solver-provision` (ordered
# ahead of it by `depends_on` in this fragment) and `poster-provision` (in compose/poster.yml,
# which `depends_on` cannot reach across). All three take this lock. See take_genesis_lock()
# in images/offerfiles-kernel/entrypoint-common.sh.
take_genesis_lock

wait_http "${ZSWAP_API}/v1/health" "kernel API" "${KERNEL_WAIT_TIMEOUT_S:-600}" \
  || die "the kernel API never answered — nowhere to post an offer"

cd "${REPO_ROOT}" || die "no ${REPO_ROOT}"
log "posting one maker offer into the kernel book (proving — this takes a while)"

# tee, so the offer's own identity can be recovered from the output while the operator still
# sees every line as it happens. `pipefail` is set by the prelude, so the posting script's
# exit status is what this pipeline reports.
POST_LOG="${MARKER_DIR}/.last-post.log"
POST_RC=0
bun run deploy/scripts/post-maker-offer.ts 2>&1 | tee "${POST_LOG}" || POST_RC=$?

if [ "${POST_RC}" -eq 0 ]; then
  # `offer <12 hex>… is LIVE in the kernel order book` is the line; anything else means the
  # script changed and the marker simply carries no hash — which verify.sh handles.
  PREFIX="$(grep -oE 'offer [0-9a-f]{12}' "${POST_LOG}" | tail -1 | sed 's/^offer //' || true)"
  OFFER_HASH=""
  if [ -n "${PREFIX}" ]; then
    OFFER_HASH="$(offer_hash_for_prefix "${PREFIX}" || true)"
  fi
  {
    date -u +%Y-%m-%dT%H:%M:%SZ
    if [ -n "${OFFER_HASH}" ]; then
      echo "offerHash=${OFFER_HASH}"
    fi
    echo "give=${GIVE_AMOUNT:-500000} want=${WANT_AMOUNT:-750000}"
  } > "${MARKER}"
  if [ -n "${OFFER_HASH}" ]; then
    log "maker offer live as ${OFFER_HASH}; marker written to ${MARKER}"
  else
    log "maker offer live; marker written to ${MARKER} (offer hash not resolvable from the log)"
  fi
  exit 0
fi

# Fail loudly: a book with no offers is indistinguishable, from the outside, from a solver
# that is working perfectly and simply has nothing to quote.
log "ERROR: could not post the maker offer — the solver will publish an EMPTY ladder"
log "ERROR: (nothing to quote). The cause is in the log above."
exit 1
