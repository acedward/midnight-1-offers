#!/usr/bin/env bash
# offer-poster — the long-running offer poster. THE ONLY LOOP IN THIS IMAGE.
#
# Every POST_INTERVAL_MS (60 s by default) one tick does exactly one of two things:
#
#   re-offer   a coin the journal already owns has come back (its last offer is `expired` or
#              `cancelled` in the kernel AND its nonce is visible again in the wallet's
#              availableCoins), so the tick posts a fresh offer for that exact coin; or
#   inventory  no journal coin is free, so the tick ADOPTS one unjournaled spendable coin whose
#              value is EXACTLY GIVE_AMOUNT and offers that.
#
# Either way the offer SPENDS ITS COIN WHOLE: no change output, so every offer on the book is
# a complete, independent swap rather than a slice of a shared balance. The want leg is
# `suggested_to_amount` from the kernel's own `GET /v1/quote`, which lands the offer exactly
# on the sponsorship threshold so the batcher pays its Celestia fee.
#
# ── IT DOES NOT MINT ANY MORE, AND THAT CHANGES THE PROFILE (00020 PR C) ────
# Up to `KERNEL_REF=a608fa6…` a tick with nothing free MINTED a fresh coin from the kernel's
# own faucet circuit, paying the fee out of its own DUST. Kernel #69 deleted that contract and
# `selectInventoryCoin()` replaced the mint: the poster now picks one coin it ALREADY HOLDS
# whose `value` EQUALS `GIVE_AMOUNT` — not one worth at least that much — and reports
# `degraded: insufficient_inventory` when none matches. It does not die; a degraded tick is not
# a failed tick and `/health` still answers 200 (503 arrives only after HEALTH_STALE_TICKS
# consecutive FAILED ticks).
#
# So the book is now BOUNDED by prefunded inventory. `poster-premint` mints
# POSTER_PREMINT_COUNT coins of exactly GIVE_AMOUNT through the issuer before this service
# starts, and once they are all live the poster keeps re-offering released coins and reports
# `insufficient_inventory` on any tick that has nothing to re-offer. The refill command is in
# docs/OPERATIONS.md; the budget is in docs/KNOWN-LIMITATIONS.md.
#
# This is a PORT of the kernel repository's own `deploy/images/kernel/entrypoint-offer-poster.sh`
# onto m1's entrypoint-common.sh; the process it execs is the pinned kernel's own
# `deploy/scripts/offer-poster.ts`, unmodified.
#
# ── WHY THERE IS NO MARKER FILE ──────────────────────────────────────────────
# Every other one-shot in this stack writes one and exits early on a restart, because
# re-running them would re-prove and re-post the same seeding artifact on every bounce. This
# service is the opposite — a LOOP whose whole job is to keep posting, so a marker would make
# a restart a permanent no-op. Idempotence lives one level down instead, in the JOURNAL
# (POSTER_JOURNAL_FILE, on the `poster-state` volume): it is written BEFORE an adopted coin is
# offered and after every state change, so a restart re-adopts the coins this poster already
# owns and re-offers the ones that came back rather than duplicating inventory. Deleting that
# volume — i.e. `./down.sh -v` — is what "start over" means here. At this pin the journal is
# keyed by NETWORK ID and GIVE-TOKEN ID rather than by a contract address, and it refuses to
# open against a mismatch rather than merging.
#
# ── ONE FACADE PER SEED, EVER ────────────────────────────────────────────────
# Two wallet facades on one seed against one Midnight node force each other's connection down
# (wallets/wallets.json). OFFER_POSTER_SEED must therefore be a DEDICATED seed, and this
# service must never be scaled past one replica. `deploy/scripts/lib/poster-config.ts`
# refuses to start (exit 78) if POSTER_SEED collides with MIDNIGHT_WALLET_SEED,
# MIDNIGHT_GENESIS_SEED, BATCHER_WALLET_SEED, SOLVER_SEED, MAKER_SEED, MAKER_OFFER_SEED or
# TAKER_SEED **as it sees them in its own environment** — which is exactly why
# compose/poster.yml spells the four Midnight endpoints out on this service instead of
# merging the shared endpoints anchor: that anchor carries MIDNIGHT_WALLET_SEED.
#
# `exec` matters: the poster installs SIGTERM/SIGINT handlers that flush the journal and stop
# the wallet within SHUTDOWN_GRACE_MS, and only PID 1 gets Compose's signal.

# Consumed by log() in the sourced prelude, which shellcheck cannot see from here.
# shellcheck disable=SC2034
ROLE=offer-poster
# shellcheck source=images/offerfiles-kernel/entrypoint-common.sh
. /usr/local/lib/offerfiles/entrypoint-common.sh

# The four the container cannot sensibly default. GIVE_TOKEN/WANT_TOKEN joined this list at
# KERNEL_REF=e3b9388… — `resolveLeg()` makes them required with no fallback of any kind — and
# failing here means failing before the kernel wait rather than after it. The WALLET is
# deliberately NOT checked by require_env: POSTER_SEED xor POSTER_MNEMONIC is an exclusive
# choice with a collision rule attached, and poster-config.ts reports all of that in one place
# with the same exit code.
require_env ZSWAP_API MIDNIGHT_NETWORK_ID GIVE_TOKEN WANT_TOKEN

# The wallet, checked here rather than by poster-config.ts alone, because the two sides have
# DIFFERENT NAMES: the process reads POSTER_SEED / POSTER_MNEMONIC, the operator sets
# OFFER_POSTER_SEED / OFFER_POSTER_MNEMONIC in .env. poster-config.ts reports the first pair
# (it cannot know the second), so this line bridges them — and it fails BEFORE the contract
# wait and the kernel wait below, which is the whole point of doing it in the shell.
#
# Compose's own `${VAR:?message}` guard would be the obvious place for this and is
# deliberately not used: compose interpolates EVERY service before it filters by profile, and
# m1 has no `profiles:` keys at all — a `:?` here would make every `docker compose config`
# in this repository fail for an operator who never asked for the poster.
if [ -z "${POSTER_SEED:-}" ] && [ -z "${POSTER_MNEMONIC:-}" ]; then
  log "missing required environment: POSTER_SEED or POSTER_MNEMONIC"
  log "set OFFER_POSTER_SEED (or OFFER_POSTER_MNEMONIC) in .env — a DEDICATED seed, not the"
  log "genesis / batcher / solver / maker / taker one. wallets/wallets.json reserves"
  log "…0041 for the poster and compose/poster.yml ships it as the default."
  exit 78 # EX_CONFIG, the same code poster-config.ts uses
fi

# ── "" IS NOT "unset" ────────────────────────────────────────────────────────
# Compose cannot express "leave this variable out", and `readEnv` in poster-config.ts already
# treats a blank value as absent — so this is belt-and-braces rather than load-bearing. It
# keeps the container's environment HONEST: `docker compose exec offer-poster env` then shows
# what the process actually used, and a reader of `${WANT_AMOUNT:-}` in the fragment is not
# misled into thinking an empty string forces a want amount of zero.
#
# POSTER_SEED / POSTER_MNEMONIC are NOT in this list: leaving one blank must reach the config
# parser and be reported as the missing wallet it is.
# GIVE_TOKEN and WANT_TOKEN are NOT in this list: at this pin they are REQUIRED and a blank
# one must reach `resolveLeg()` and be reported as the missing token it is. The four knobs
# kernel #69 deleted — GIVE_SIZE_SEED, COIN_VISIBLE_TIMEOUT_MS, POSTER_MIN_DUST and
# POSTER_DUST_WAIT_TIMEOUT_MS — are not in it either, because they are not passed at all any
# more: `poster-config.ts` no longer reads them, and compose no longer sets them.
unset_if_empty GIVE_AMOUNT GIVE_MIN GIVE_MAX \
               WANT_AMOUNT POST_INTERVAL_MS OFFER_TTL_MINUTES \
               RECONCILE_INTERVAL_MS \
               POSTER_MAX_REOFFERS_PER_TICK SHUTDOWN_GRACE_MS HEALTH_STALE_TICKS \
               POSTER_HEALTH_PORT DRY_RUN POSTER_JOURNAL_FILE POSTER_JOURNAL_RESET \
               POSTER_SYNC_TIMEOUT_MS \
               POSTER_POST_RETRIES POSTER_POST_RETRY_MS POSTER_LIVE_TRIES \
               POSTER_LIVE_INTERVAL_MS

# ── THE TWO TOKEN IDS (00020 PR C) ──────────────────────────────────────────
# `resolveLeg()` at this pin requires an EXPLICIT 64-hex token id and refuses a name outright
# ("GIVE_TOKEN is required: set the 64-hex token ID from the selected network's external
# registry"). Those ids are per-chain — the issuer deploys six contracts and each token's
# colour derives from its contract address — so they cannot be written into compose or .env.
#
# This stack therefore lets an operator configure a NAME (`TWBTC`) and resolves it from the
# handoff the `issuer` profile publishes, leaving a raw 64-hex value untouched so a deliberate
# override still works. A name that is not one of this stack's six fails HERE, with the six
# listed, rather than as a 64-hex validation error about a value the operator never typed.
#
# `resolve_token_leg` lives in registry-env.sh because the maker and the solver lane need
# exactly the same translation — see that file.
resolve_token_leg GIVE_TOKEN
resolve_token_leg WANT_TOKEN

wait_http "${ZSWAP_API}/v1/health" "kernel API" "${KERNEL_WAIT_TIMEOUT_S:-600}" \
  || die "the kernel API never answered — nowhere to post an offer"

# The journal's own volume. openJournal() mkdir -p's this too; doing it here as well means a
# wrong POSTER_JOURNAL_FILE (a path outside the mount, a typo) fails as a plain mkdir error
# before the wallet spends three minutes syncing.
POSTER_JOURNAL_DIR="$(dirname "${POSTER_JOURNAL_FILE:-/var/lib/offer-poster/journal.json}")"
mkdir -p "${POSTER_JOURNAL_DIR}"

cd "${REPO_ROOT}" || die "no ${REPO_ROOT}"
log "starting the offer poster (deploy/scripts/offer-poster.ts)"
log "  kernel=${ZSWAP_API} network=${MIDNIGHT_NETWORK_ID} journal=${POSTER_JOURNAL_FILE:-/var/lib/offer-poster/journal.json}"
# BASE UNITS on both sides of the range now, not whole coins: kernel #69 replaced the
# log-uniform whole-coin draw with an inclusive base-unit FILTER over coins the wallet already
# holds. Printing "coins" here would be a claim about a token whose decimals this line does
# not know.
if [ -n "${GIVE_MIN:-}" ] || [ -n "${GIVE_MAX:-}" ]; then
  log "  give=${M1_GIVE_TOKEN_NAME:-${GIVE_TOKEN:0:16}…}/${GIVE_MIN:-<unset>}..${GIVE_MAX:-<unset>} BASE UNITS (selects a prefunded coin in that range)"
else
  log "  give=${M1_GIVE_TOKEN_NAME:-${GIVE_TOKEN:0:16}…}/${GIVE_AMOUNT:-1} BASE UNITS exactly (selects a prefunded coin of that size)"
fi
log "  want=${M1_WANT_TOKEN_NAME:-${WANT_TOKEN:0:16}…}/${WANT_AMOUNT:-<quoted>} interval=${POST_INTERVAL_MS:-60000}ms"
log "  giveToken=${GIVE_TOKEN} wantToken=${WANT_TOKEN}"
exec bun run deploy/scripts/offer-poster.ts
