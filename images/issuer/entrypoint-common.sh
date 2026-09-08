#!/usr/bin/env bash
# entrypoint-common.sh — the shared prelude for the issuer image's four roles.
# SOURCED, never executed.
#
# One image ships one process per concern — the deploy one-shot, the kernel registrar, the
# funding CLI and the registry reporter — and they all start the same way: normalise the
# environment compose handed them, write the seeds to a tmpfs, and (for the two that touch a
# chain) prove the stack is actually ready rather than merely started.
#
# WHAT THIS FILE DELIBERATELY DOES NOT DO: supply endpoint defaults.
# mint-test-tokens' `undeployed` config already defaults to 127.0.0.1, and inside a container
# 127.0.0.1 means "nothing is there". A second layer of defaults here would turn "compose
# forgot to state an endpoint" into a connection timeout against localhost instead of the
# configuration error it is. Every endpoint is stated explicitly in compose/issuer.yml, and
# `require_env` makes a missing one fatal and named.
#
# Probes use `curl`, which the Dockerfile INSTALLS and ASSERTS (it is NOT in the slim node
# base — measured the hard way: the first bring-up of this profile spent its whole node-block
# wait on `curl: not found` swallowed by `2>/dev/null`). The bun-based images in this
# repository probe with `bun -e fetch` because their base ships no curl and installing one for
# a probe would grow the image for nothing; here the base is Debian, `node -e` would pay Node's
# startup cost on every one of a hundred poll iterations, and an operator debugging a one-shot
# by hand wants curl anyway.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/app}"
# The registry DIRECTORY, never the file. Upstream is explicit about why: atomic publication
# replaces the file's inode, so a single-file bind mount can stay attached to the previous
# snapshot. Every consumer reopens `metadata.undeployed.json` inside this directory by path.
ISSUER_REGISTRY_DIR="${MN_METADATA_OUTPUT_DIR:-/srv/issuer-registry}"
# shellcheck disable=SC2034  # read by the entrypoints that SOURCE this file
ISSUER_REGISTRY_FILE="${ISSUER_REGISTRY_DIR}/metadata.undeployed.json"
# THE TOKEN HANDOFF DIRECTORY (00020 PR C), and a DIRECTORY for the same reason: `tokens.env`
# is published by rename, which replaces the inode. It is deliberately NOT inside
# ISSUER_REGISTRY_DIR — that directory is an nginx document root on the `faucet` service, and
# "the token handoff happens to live in a web root" is a property nobody should have to
# re-check. Only `issuer-deploy` and `issuer-tokens-env` mount it read-write; every consumer
# mounts it read-only.
# shellcheck disable=SC2034  # read by the entrypoints that SOURCE this file
ISSUER_TOKENS_DIR="${ISSUER_TOKENS_DIR:-/srv/issuer-tokens}"
# shellcheck disable=SC2034
ISSUER_TOKENS_FILE="${ISSUER_TOKENS_DIR}/tokens.env"
# EXPORTED, because `m1/tokens-env.ts` reads it out of the environment rather than being
# handed a path — one name, one default, in one place.
export ISSUER_TOKENS_DIR
# Where the resume journal and the private-state stores live. It is <repo root>/.local because
# that is where `scripts/v1-deploy.ts` puts them (`resolve(root, ".local", …)`), keyed by
# sha256(output path + stack identity) — not a path this stack chose, and not one it can move
# without patching upstream. compose mounts the `issuer-state` volume over it.
ISSUER_STATE_DIR="${ISSUER_STATE_DIR:-${REPO_ROOT}/.local}"

log() { printf '[%s] %s\n' "${ROLE:-issuer}" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# ── "" IS NOT "unset" ────────────────────────────────────────────────────────
# Compose cannot express "leave this variable out": `FOO: ${FOO}` with FOO absent from .env
# renders as FOO="" and the container sees a variable that is PRESENT and empty. The upstream
# runner reads its optional knobs with `process.env.X?.trim() || <default>`, which treats ""
# as absent — but `MN_REDEPLOY_STALE` and `MN_CONFIRM_NO_DEPLOYMENT` are compared to the
# literal "1", and `MN_WALLET_CHECKPOINT_VALIDATE_ONLY` THROWS on any value that is neither
# unset nor "1". So an operator who merely left that knob blank would crash the runner on a
# configuration error it could not name. Unset the blank ones here instead.
#
# ONLY genuinely optional knobs belong here. Anything part of a launch contract must reach its
# process still empty, so the process can report it as missing.
unset_if_empty() {
  local name
  for name in "$@"; do
    if [ -z "${!name:-}" ]; then unset "${name}"; fi
  done
}
unset_if_empty MN_REDEPLOY_STALE MN_CONFIRM_NO_DEPLOYMENT MN_WALLET_CHECKPOINT_FILE \
               MN_WALLET_CHECKPOINT_VALIDATE_ONLY SOURCE_REVISION MN_TIMEOUT_MS \
               ISSUER_SDK_LOG_LEVEL

# ── fail loudly on a TOOL that is not there ──────────────────────────────────
#
# THIS EXISTS BECAUSE OF A REAL FAILURE, and the failure mode is the point. `curl` is not in
# the slim node base; the Dockerfile installs and asserts it. But the probes below redirect
# stderr to /dev/null (they must — a connection refused every two seconds is not worth
# printing), so on an image WITHOUT curl every probe simply "failed to connect" and the
# bring-up spent its entire 600-second node-block budget on `curl: not found`, then timed out
# with a message naming the NODE. One line here turns that into the configuration error it is.
#
# Checked at source time, before any endpoint is read, so every role gets it.
require_tools() {
  local missing="" tool
  for tool in "$@"; do
    command -v "${tool}" >/dev/null 2>&1 || missing="${missing} ${tool}"
  done
  if [ -n "${missing}" ]; then
    log "MISSING TOOL(S) IN THIS IMAGE:${missing}"
    log "images/issuer/Dockerfile installs and asserts git, psql, curl, getent and flock in the"
    log "runtime target. A base-image change that dropped one lands here, not as a probe that"
    log "silently never succeeds."
    exit 78   # EX_CONFIG
  fi
}
require_tools curl git flock getent

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

# ── the seeds ────────────────────────────────────────────────────────────────
#
# THE UPSTREAM RUNNER ONLY ACCEPTS A FILE (`MN_SEED_FILE`, "They accept a funded wallet master
# seed only through a private file; they never write the seed into metadata or deployment
# journals"), and that is exactly the property this stack wants: an argument is visible in
# `docker inspect`, in `ps` and in every compose log line that echoes a command, while a file
# on a tmpfs is visible to this container and nothing else.
#
# /run is a tmpfs in the compose fragment, so the file never touches a layer or a volume, and
# 0600 because nothing else in the container needs to read it.
#
# THE SEEDS THEMSELVES ARE PUBLIC DEVNET VALUES from wallets/wallets.json — this is not secrecy
# theatre, it is the same hygiene every other wallet-holding container here follows, so that a
# stack pointed at a real network by mistake does not additionally leak its key into a log.
SEED_DIR="${SEED_DIR:-/run/issuer}"

# write_seed_file <variable-name> <basename> — validate a 64/128-hex seed from the environment,
# write it to the tmpfs, and print the path on STDOUT. Refuses anything that is not a seed, so
# the failure names the variable instead of arriving as "MN_SEED_FILE must contain exactly 32 or
# 64 bytes" from inside the SDK.
#
# It RETURNS 78 rather than calling `exit`, because every caller invokes it inside a command
# substitution: `exit` there would end the SUBSHELL, and a caller that did not check the status
# would carry on with an empty path. Callers therefore write
#     VAR="$(write_seed_file X x.hex)" || exit 78
# and the refusal reason is already on stderr.
write_seed_file() {
  local var="$1" base="$2" value path
  value="$(printf '%s' "${!var:-}" | tr -d '[:space:]' | sed -e 's/^0[xX]//')"
  case "${value}" in
    "") log "${var} is empty"; return 78 ;;
  esac
  # 32 bytes (64 hex) or 64 bytes (128 hex) — the pinned tree's own rule, restated so the
  # failure happens before a wallet is built.
  case "${#value}" in
    64|128) : ;;
    *) log "${var} must be 64 or 128 hex characters (32 or 64 bytes), got ${#value}"; return 78 ;;
  esac
  case "${value}" in
    *[!0-9a-fA-F]*) log "${var} is not hexadecimal"; return 78 ;;
  esac
  mkdir -p "${SEED_DIR}" || { log "cannot create ${SEED_DIR}"; return 1; }
  path="${SEED_DIR}/${base}"
  # `install -m 0600 /dev/null` first so the file is never briefly world-readable.
  install -m 0600 /dev/null "${path}" || { log "cannot create ${path}"; return 1; }
  printf '%s' "${value}" > "${path}"
  printf '%s' "${path}"
}

# ── readiness ────────────────────────────────────────────────────────────────
#
# EVERY wait FAILS the caller rather than warning. A deploy that starts against a half-ready
# stack does not fail here — it fails later, somewhere unrelated, with an error that names the
# wrong component.

# wait_http <url> <label> [timeout_s]
#
# ANY HTTP response counts as "listening", including a 404 or a 405: what is being waited on is
# a socket that answers, not a particular status. `-o /dev/null` because a GraphQL endpoint
# answers a bare GET with a page nobody here wants in the log.
wait_http() {
  local url="$1" label="$2" timeout="${3:-300}" waited=0
  log "waiting for ${label} at ${url} (timeout ${timeout}s)"
  until curl -sS -o /dev/null --max-time 5 "${url}" >/dev/null 2>&1; do
    waited=$(( waited + 2 ))
    if [ "${waited}" -ge "${timeout}" ]; then
      log "TIMEOUT after ${timeout}s waiting for ${label} at ${url}"
      return 1
    fi
    sleep 2
  done
  log "${label} is up"
}

# node_rpc <method> [params-json] — one JSON-RPC call, the raw body on stdout.
node_rpc() {
  local method="$1" params="${2:-[]}"
  curl -sS --max-time 8 -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"${method}\",\"params\":${params}}" \
    "${MN_NODE_URL}" 2>/dev/null || printf ''
}

# node_height — the best block height as a decimal, or empty. `|| true` throughout: an
# unreadable tip must never kill a script under `pipefail`.
node_height() {
  local body hex
  body="$(node_rpc chain_getHeader)"
  hex="$(printf '%s' "${body}" | sed -n 's/.*"number":"0x\([0-9a-fA-F]*\)".*/\1/p' | head -1 || true)"
  [ -n "${hex}" ] || return 0
  printf '%d' "$(( 16#${hex} ))"
}

# wait_node_block <min-block> [timeout_s]
#
# Compose health is not readiness for a Substrate chain: the node answers RPC long before it
# has produced anything, and both the deploy and every mint prove and submit a real
# transaction. Until finality has moved off genesis the wallet refuses to build one at all.
wait_node_block() {
  local min_block="${1:-1}" timeout="${2:-600}" waited=0
  log "waiting for midnight-node block #${min_block} at ${MN_NODE_URL} (timeout ${timeout}s)"
  until printf '%s' "$(node_rpc chain_getBlockHash "[${min_block}]")" | grep -q '"result":"0x' ; do
    waited=$(( waited + 2 ))
    if [ "${waited}" -ge "${timeout}" ]; then
      log "TIMEOUT after ${timeout}s waiting for block #${min_block}"
      return 1
    fi
    sleep 2
  done
  log "midnight-node has block #${min_block}"
}

# wait_for_stack — the three core services this profile depends on, and nothing else. Re-proved
# per container rather than inherited from bring-up: a container that comes back after its
# dependencies moved must not inherit a stale all-clear.
wait_for_stack() {
  wait_node_block 1 "${NODE_BLOCK_TIMEOUT_S:-600}" || die "midnight-node produced no block"
  wait_http "${MN_PROOF_SERVER_URL}" "proof-server" "${PROOF_WAIT_TIMEOUT_S:-300}" \
    || die "proof-server never answered"
  wait_http "${MN_INDEXER_URL}" "indexer" "${INDEXER_WAIT_TIMEOUT_S:-300}" \
    || die "indexer never answered"
}

# ── the genesis-1 facade mutex (00011 Q7) ────────────────────────────────────
# FOUR one-shots in this stack now drive a wallet facade on the SAME seed — genesis-1:
#
#   solver-provision   funds the solver's NIGHT from genesis        (compose/solver.yml)
#   maker-offer        posts the seeded book offer FROM genesis     (compose/solver.yml)
#   poster-provision   sends the poster four large NIGHT UTXOs      (compose/poster.yml)
#   issuer-deploy      sends the ISSUER four large NIGHT UTXOs      (compose/issuer.yml)
#
# Two facades on one seed against one node force each other's connection down (the rule at the
# top of wallets/wallets.json), and the four live in three different fragments. A `depends_on`
# cannot serialise across fragments: compose refuses to render a dependency on a service that
# is not in the merged set, and `--with issuer` WITHOUT `--with solver` is a supported
# combination. So they take a `flock` instead, on a file on a named volume every fragment
# declares identically (compose merges duplicate volume declarations).
#
# NO SOFT BRANCH, deliberately. `mkdir -p` succeeds whether or not the shared volume is
# mounted: with the volume the lock is shared between containers, without it the lock is
# container-local and the call is simply a no-op — which is exactly right for a stack where
# only one of the four services exists.
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
  log "  docker compose logs issuer-deploy solver-provision maker-offer poster-provision"
  die "timed out waiting for the genesis-1 facade lock"
}

# Give the lock back EARLY, for the case holding it to process exit is wasteful: this profile's
# deploy one-shot finishes with genesis in under a minute and then spends many minutes proving
# six contract deployments on its OWN wallet.
release_genesis_lock() {
  exec 9>&- 2>/dev/null || true
  log "genesis-1 facade lock released"
}

# ── the issuer facade mutex ──────────────────────────────────────────────────
# The issuer's own seed has the same one-facade rule, and unlike genesis it is driven by things
# an OPERATOR runs by hand: `issuer-fund` is a `docker compose run`, and phase C's provisioning
# one-shots will call it several times. Two concurrent runs would open two facades on …0051 and
# silently take each other's sync down, so they serialise on a lock on the `issuer-state`
# volume — the same volume that holds the resume journal, so the lock and the state it protects
# are wiped together by `./down.sh -v`.
ISSUER_LOCK_FILE="${ISSUER_LOCK_FILE:-${ISSUER_STATE_DIR}/.issuer-facade.lock}"

take_issuer_lock() {
  local timeout="${ISSUER_LOCK_TIMEOUT_S:-3600}"
  mkdir -p "${ISSUER_STATE_DIR}" || die "cannot create ${ISSUER_STATE_DIR}"
  exec 8>"${ISSUER_LOCK_FILE}" || die "cannot open ${ISSUER_LOCK_FILE}"
  log "waiting for the issuer facade lock (${ISSUER_LOCK_FILE}, up to ${timeout}s)"
  if flock -w "${timeout}" 8; then
    log "issuer facade lock ACQUIRED"
    return 0
  fi
  log "another issuer container has held the issuer facade for ${timeout}s:"
  log "  docker compose logs issuer-deploy   ·   docker compose ps -a"
  die "timed out waiting for the issuer facade lock"
}
