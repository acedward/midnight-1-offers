#!/usr/bin/env bash
# entrypoint-common.sh — the shared prelude for all three offer-files containers.
# SOURCED, never executed.
#
# One image ships one process per concern — the deploy one-shot, the sync node, the batcher —
# and all three start the same way: normalise the environment compose handed them, pick up the
# Celestia auth token off a shared volume, and (for the two that need one) learn the offer-files
# contract address the one-shot published.
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
CONTRACT_SHARE_DIR="${CONTRACT_SHARE_DIR:-/srv/offerfiles-deploy}"
NETWORK_ID="${MIDNIGHT_NETWORK_ID:-undeployed}"
# The name is not a convention this repository invented: `midnight-contract:deploy` writes,
# and `readMidnightContract()` reads, exactly `contract-offer-files.<network>.json` inside
# packages/contracts-midnight.
CONTRACT_FILE="contract-offer-files.${NETWORK_ID}.json"
CONTRACT_TARGET_DIR="${REPO_ROOT}/packages/contracts-midnight"
# Read by the entrypoints that SOURCE this file (deploy publishes both, token-names reads
# the first), which shellcheck cannot see from inside the library.
# shellcheck disable=SC2034
MINTED_FILE="minted-tokens.json"
# shellcheck disable=SC2034
MINT_MARKER="${CONTRACT_SHARE_DIR}/.minted"

log() { printf '[%s] %s\n' "${ROLE:-offerfiles}" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

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

# ── the contract address ─────────────────────────────────────────────────────
# The deploy one-shot persists `contract-offer-files.<network>.json` on the shared volume.
# Readers adopt it TWO ways, and neither is redundant:
#
#   1. copied into packages/contracts-midnight/, because that is the literal path
#      `readMidnightContract()` and the mint script resolve — nothing in the kernel
#      repository had to change for this to work;
#   2. exported as MIDNIGHT_CONTRACT_ADDRESS, which the same reader prefers over the file,
#      and which makes "which contract is this container on?" answerable from
#      `docker inspect` and from the logs without exec'ing into anything.
#
# Copied and not symlinked: the source sits on a read-only volume and the reader resolves
# paths relative to the package directory.
adopt_contract_address() {
  local src="${CONTRACT_SHARE_DIR}/${CONTRACT_FILE}"
  local timeout="${CONTRACT_WAIT_TIMEOUT_S:-900}" waited=0

  # compose already gates these containers on `service_completed_successfully`, so in the
  # ordinary case this loop does not spin once. It exists for the case compose cannot cover:
  # a container restarted by its own restart policy while the volume is being written.
  while [ ! -f "${src}" ]; do
    waited=$(( waited + 2 ))
    if [ "${waited}" -ge "${timeout}" ]; then
      log "TIMEOUT after ${timeout}s waiting for ${src}"
      die "the offerfiles-deploy one-shot has published no contract address"
    fi
    sleep 2
  done

  install -m 0644 "${src}" "${CONTRACT_TARGET_DIR}/${CONTRACT_FILE}"

  # Path via ENV, not argv: `bun -e` builds process.argv as ["<bun>", ...trailing args] with
  # no script-path entry, so the usual argv[2] is undefined.
  local address
  address="$(OFFERFILES_CONTRACT_JSON="${src}" bun -e '
    const json = await Bun.file(process.env.OFFERFILES_CONTRACT_JSON).json();
    const value = json.contractAddress;
    if (typeof value !== "string" || value.length === 0) {
      console.error("contract file carries no string contractAddress");
      process.exit(1);
    }
    process.stdout.write(value);
  ')" || die "${CONTRACT_FILE} is unreadable or carries no contractAddress"

  export MIDNIGHT_CONTRACT_ADDRESS="${address}"
  log "offer-files contract ${MIDNIGHT_CONTRACT_ADDRESS} (network ${NETWORK_ID})"
}

# ── the genesis-1 facade mutex (00011 Q7) ────────────────────────────────────
# THREE one-shots in this stack drive a wallet facade on the SAME seed — genesis-1:
#
#   solver-provision   funds the solver's NIGHT from genesis before minting its inventory
#   maker-offer        posts the seeded book offer FROM the genesis wallet (it is the only
#                      wallet the deploy one-shot's mint credited)
#   poster-provision   sends the poster four large NIGHT UTXOs from genesis
#
# Two facades on one seed against one node force each other's connection down (the rule at
# the top of wallets/wallets.json), and the first two live in `compose/solver.yml` while the
# third lives in `compose/poster.yml`. A `depends_on` cannot serialise across fragments:
# compose refuses to render a dependency on a service that is not in the merged set, and
# `--with poster` WITHOUT `--with solver` is a supported combination. So the three take a
# `flock` instead, on a file on a named volume both fragments declare identically (compose
# merges duplicate volume declarations).
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
  log "  docker compose logs solver-provision maker-offer poster-provision"
  die "timed out waiting for the genesis-1 facade lock"
}

# Give the lock back EARLY, for the one case where holding it to process exit is wasteful:
# a service that finishes with genesis and then spends minutes on its own wallet.
release_genesis_lock() {
  exec 9>&- 2>/dev/null || true
  log "genesis-1 facade lock released"
}
