#!/usr/bin/env bash
# offer-poster — the long-running offer poster. THE ONLY LOOP IN THIS IMAGE.
#
# Every POST_INTERVAL_MS (60 s by default) one tick does exactly one of two things:
#
#   re-offer  a coin the journal already owns has come back (its last offer is `expired` or
#             `cancelled` in the kernel AND its nonce is visible again in the wallet's
#             availableCoins), so the tick posts a fresh offer for that exact coin; or
#   mint      no coin is free, so the tick calls the faucet circuit
#             `mint_shielded(domainSep(GIVE_TOKEN), GIVE_AMOUNT, freshNonce)` — paying the
#             mint fee from its OWN DUST — waits for the coin, and offers it.
#
# Either way the offer SPENDS ITS COIN WHOLE: no change output, so every offer on the book is
# a complete, independent swap rather than a slice of a shared balance. The want leg is
# `suggested_to_amount` from the kernel's own `GET /v1/quote`, which lands the offer exactly
# on the sponsorship threshold so the batcher pays its Celestia fee.
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
# (POSTER_JOURNAL_FILE, on the `poster-state` volume): it is written BEFORE a mint is
# submitted and after every state change, so a restart re-adopts the coins this poster
# already owns and re-offers the ones that came back rather than minting a fresh set.
# Deleting that volume — i.e. `./down.sh -v` — is what "start over" means here.
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

# The two the container cannot sensibly default. The WALLET is deliberately NOT checked by
# require_env: POSTER_SEED xor POSTER_MNEMONIC is an exclusive choice with a collision rule
# attached, and poster-config.ts reports all of that in one place with the same exit code.
require_env ZSWAP_API MIDNIGHT_NETWORK_ID

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
unset_if_empty GIVE_TOKEN GIVE_AMOUNT GIVE_MIN GIVE_MAX GIVE_SIZE_SEED \
               WANT_TOKEN WANT_AMOUNT POST_INTERVAL_MS OFFER_TTL_MINUTES \
               COIN_VISIBLE_TIMEOUT_MS RECONCILE_INTERVAL_MS \
               POSTER_MAX_REOFFERS_PER_TICK SHUTDOWN_GRACE_MS HEALTH_STALE_TICKS \
               POSTER_HEALTH_PORT DRY_RUN POSTER_JOURNAL_FILE POSTER_JOURNAL_RESET \
               POSTER_MIN_DUST POSTER_SYNC_TIMEOUT_MS POSTER_DUST_WAIT_TIMEOUT_MS \
               POSTER_POST_RETRIES POSTER_POST_RETRY_MS POSTER_LIVE_TRIES \
               POSTER_LIVE_INTERVAL_MS

# The contract address, from the shared offerfiles-deploy volume. The poster resolves it
# itself in the same priority order (MIDNIGHT_CONTRACT_ADDRESS → the share dir → the copy in
# packages/contracts-midnight), so this call is what makes the first branch true — and the
# JOURNAL IS KEYED BY THAT ADDRESS: a journal from another deployment is refused at startup
# rather than merged, because those coins do not exist on this chain.
adopt_contract_address

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
if [ -n "${GIVE_MIN:-}" ] || [ -n "${GIVE_MAX:-}" ]; then
  # A RANGE: the size is drawn log-uniformly per FRESH mint, so there is no single number to
  # print here. The poster's own banner prints the resolved base units for each mint.
  log "  give=${GIVE_TOKEN:-WBTC}/${GIVE_MIN:-<unset>}..${GIVE_MAX:-<unset>} coins (log-uniform per mint, seed=${GIVE_SIZE_SEED:-<random>})"
else
  log "  give=${GIVE_TOKEN:-WBTC}/${GIVE_AMOUNT:-1000000}"
fi
log "  want=${WANT_TOKEN:-WETH}/${WANT_AMOUNT:-<quoted>} interval=${POST_INTERVAL_MS:-60000}ms"
exec bun run deploy/scripts/offer-poster.ts
