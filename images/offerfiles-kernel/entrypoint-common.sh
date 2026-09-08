#!/usr/bin/env bash
# entrypoint-common.sh — the shared prelude for every offer-files container.
# SOURCED, never executed.
#
# One image ships one process per concern — the sync node, the batcher, the poster, the price
# feed, and (through images/cow-solver) the solver lane — and they all start the same way:
# normalise the environment compose handed them, and pick up the Celestia auth token off a
# shared volume.
#
# ── WHAT LEFT THIS FILE IN 00020 PR C ────────────────────────────────────────
# `adopt_contract_address()`, `CONTRACT_SHARE_DIR`, `CONTRACT_FILE`, `MINTED_FILE` and
# `MINT_MARKER`. Kernel #69 deleted the offer-files contract, so there is no address to adopt
# and no `minted-tokens.json` to read: the kernel's `GET /v1/midnight/config` no longer carries
# a `contractAddress`, upstream's own `entrypoint-common.sh` dropped the same function, and
# `readMidnightContract()` is gone from the tree.
#
# WHAT REPLACED IT is `registry-env.sh`, sourced below: the token IDS this stack trades are
# now ISSUED per chain by the `issuer` profile rather than derived from a contract address, and
# a consumer learns them from the handoff that profile publishes. Same shape of problem, same
# shape of answer — a per-stack identity that must be read at container start and never
# hard-coded — with the file on a different volume and a different producer.
#
# WHAT THIS FILE DELIBERATELY DOES NOT DO: supply endpoint defaults.
# `@effectstream/midnight-contracts` already defaults an unset MIDNIGHT_NETWORK_ID to
# `undeployed` with 127.0.0.1 endpoints, and inside a container 127.0.0.1 means "nothing is
# there". A second layer of defaults here would turn "compose forgot to state an endpoint"
# into a connection timeout against localhost instead of the configuration error it is. Every
# endpoint is stated explicitly in compose/offerfiles.yml, and `require_env` makes a missing
# one fatal and named.

set -euo pipefail

# shellcheck source=images/offerfiles-kernel/wait-for.sh
. /usr/local/bin/wait-for.sh

REPO_ROOT="${REPO_ROOT:-/app}"
NETWORK_ID="${MIDNIGHT_NETWORK_ID:-undeployed}"

log() { printf '[%s] %s\n' "${ROLE:-offerfiles}" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# ── the issuer's token handoff ───────────────────────────────────────────────
# Sourced HERE, unconditionally, so every entrypoint has `load_issuer_tokens`,
# `issuer_token_id`, `issuer_token_decimals` and `issuer_whole_coin` available — and sourcing
# it does nothing on its own: it defines functions and touches no file until a caller asks.
# The kernel and the batcher never call them; the poster, the solver lane and the e2e driver
# do. See that file's header for why it contains no registry parser.
#
# shellcheck source=images/offerfiles-kernel/registry-env.sh
. /usr/local/lib/offerfiles/registry-env.sh

# ── "" IS NOT "unset" ────────────────────────────────────────────────────────
# Compose cannot express "leave this variable out": `FOO: ${FOO}` with FOO absent from .env
# renders as FOO="" and the container sees a variable that is PRESENT and empty. This code
# base reads optional knobs with `getEnv(x) ?? default` and `ENV.getString(x, default)`, both
# of which treat "" as a real value — so an operator who simply left a knob blank would
# silently override a sound default with an empty string.
#
# The one that matters most is CELESTIA_NAMESPACE. An empty namespace is not an error
# anywhere: the batcher's blobs land in one namespace, the sync node subscribes to another,
# and the order book is simply always empty with nothing logged.
#
# ONLY genuinely optional knobs belong here. Anything that is part of a launch contract must
# reach its process still empty, so the process can report it as missing — softening that
# would remove the stack's fail-fast negative control.
unset_if_empty() {
  local name
  for name in "$@"; do
    if [ -z "${!name:-}" ]; then unset "${name}"; fi
  done
}
unset_if_empty CELESTIA_NAMESPACE CELESTIA_AUTH_TOKEN CELESTIA_START_HEIGHT \
               API_RATE_LIMIT_ALLOWLIST

# ── the Celestia auth-token handoff ──────────────────────────────────────────
# The token does not exist until the celestia container initialises its bridge store, which
# happens long after compose evaluated `environment:` on the host. It therefore cannot be a
# compose value, and it is not one: it arrives on a read-only volume and is sourced here, as
# each container's first act.
#
# ANYTHING COMPOSE ALREADY SET WINS over the file. That is what keeps CELESTIA_NAMESPACE
# under the stack's control rather than under the celestia container's — the file carries a
# copy of the namespace too, and a publisher/reader split on that value is silent.
load_celestia_env() {
  local handoff="${CELESTIA_ENV_FILE:-/celestia/auth/celestia.env}"
  if [ -f "${handoff}" ]; then
    local saved
    saved="$(export -p)"
    set -a
    # shellcheck disable=SC1090  # runtime path, written by the celestia container
    . "${handoff}"
    set +a
    eval "${saved}"
    log "sourced ${handoff} (compose-set values kept)"
  else
    log "no ${handoff} yet — continuing without a Celestia auth token"
  fi
}

# ── fail loudly on a variable a container cannot sensibly default ────────────
require_env() {
  local missing=() name
  for name in "$@"; do
    if [ -z "${!name:-}" ]; then missing+=("${name}"); fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    log "missing required environment: ${missing[*]}"
    exit 78   # EX_CONFIG
  fi
}

# ── the genesis-1 facade mutex (00011 Q7) ────────────────────────────────────
# THREE one-shots in this image drive a wallet facade on the SAME seed — genesis-1 — and a
# fourth in images/issuer does:
#
#   solver-provision   sends the solver four large NIGHT UTXOs from genesis, then runs
#                      upstream's external-inventory check on the solver's own wallet
#   poster-provision   sends the poster four large NIGHT UTXOs from genesis
#   maker-provision    sends the maker four large NIGHT UTXOs from genesis
#   issuer-deploy      sends the issuer four large NIGHT UTXOs from genesis (compose/issuer.yml)
#
# `maker-offer` is NO LONGER one of them (00020 PR C): its wallet used to be genesis-1, because
# the deleted faucet contract's mint credited exactly that wallet and no other held a test
# token to give away. It now has its own roster seed …0031, funded by `maker-provision` above
# and stocked with issuer tokens by `maker-inventory`, so it never opens the genesis facade.
#
# Two facades on one seed against one node force each other's connection down (the rule at
# the top of wallets/wallets.json), and these live in THREE different compose fragments. A
# `depends_on` cannot serialise across fragments: compose refuses to render a dependency on a
# service that is not in the merged set, and `--with poster` WITHOUT `--with solver` is a
# supported combination. So they take a `flock` instead, on a file on a named volume every one
# of those fragments declares identically (compose merges duplicate volume declarations).
#
# NO SOFT BRANCH, deliberately. `mkdir -p` succeeds whether or not the shared volume is
# mounted: with the volume the lock is shared between containers, without it the lock is
# container-local and the call is simply a no-op — which is exactly right for a stack where
# only one of the three services exists. `flock` itself is util-linux, present in the bun
# image's Debian base (asserted at build in images/offerfiles-kernel/Dockerfile).
#
# The lock is held on FD 9 for the life of the shell, and released by the process exiting —
# which is the one release path that cannot be skipped by an early `die`.
GENESIS_LOCK_DIR="${GENESIS_LOCK_DIR:-/srv/genesis-lock}"
GENESIS_LOCK_FILE="${GENESIS_LOCK_FILE:-${GENESIS_LOCK_DIR}/lock}"

take_genesis_lock() {
  local timeout="${GENESIS_LOCK_TIMEOUT_S:-1800}"
  mkdir -p "${GENESIS_LOCK_DIR}" || die "cannot create ${GENESIS_LOCK_DIR}"
  exec 9>"${GENESIS_LOCK_FILE}" || die "cannot open ${GENESIS_LOCK_FILE}"
  log "waiting for the genesis-1 facade lock (${GENESIS_LOCK_FILE}, up to ${timeout}s)"
  if flock -w "${timeout}" 9; then
    log "genesis-1 facade lock ACQUIRED"
    return 0
  fi
  log "another one-shot has held the genesis-1 facade for ${timeout}s. Its log names it:"
  log "  docker compose logs solver-provision poster-provision maker-provision issuer-deploy"
  die "timed out waiting for the genesis-1 facade lock"
}

# Give the lock back EARLY, for the one case where holding it to process exit is wasteful:
# a service that finishes with genesis and then spends minutes on its own wallet.
release_genesis_lock() {
  exec 9>&- 2>/dev/null || true
  log "genesis-1 facade lock released"
}
