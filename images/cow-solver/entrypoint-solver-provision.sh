#!/usr/bin/env bash
# solver-provision — give the solver something to trade with. ONE-SHOT, MANDATORY.
#
# WHY THIS IS A SERVICE AND NOT A README STEP
# -------------------------------------------
# On the pinned solver line, ladder publication is bounded by what the solver can actually
# move: a rung whose cumulative INPUT exceeds spendable tokenIn is withheld along with every
# rung above it, and a rung whose worst-case residual exceeds available tokenOut is withheld
# too. So a solver with an empty wallet publishes NOTHING, however deep the maker book behind
# it is.
#
# The failure that produces is silent and expensive, and it has been reproduced exactly:
# every service healthy, the solver connected and authenticated to the relay, `pushed 0
# pair(s)` forever, and the relay reporting one connected solver with an empty token list.
# Nothing is logged as an error anywhere. Left to a documented manual step, the default
# bring-up would produce a stack that looks perfect and quotes nothing.
#
# WHAT IT RUNS
# ------------
# `packages/solver/scripts/bootstrap-dev.ts` — the solver branch's OWN provisioner, not
# something invented here. It funds the solver's NIGHT from genesis, registers NIGHT for
# dust, mints the solver both test colours using the SAME fixed domain separators as the
# kernel's `mint-test-tokens.ts` (so the colours are IDENTICAL to the ones the deploy one-shot
# minted and the maker offer names — verified: the two scripts' separators are byte-equal
# across the two pinned commits), and writes those colours into the ladder config.
#
# ORDERING IS LOAD-BEARING: it drives a wallet on SOLVER_SEED, so the solver must not be
# running. Compose enforces that — `solver` waits on this service's
# `service_completed_successfully`. It also drives the GENESIS wallet to fund NIGHT, which is
# why `maker-offer` (the same genesis seed) waits for this one too: two wallet facades on one
# seed against one node force each other's connection down.
#
# DEVNET ONLY. This mints inventory to a public dev seed on a throwaway chain. A real
# deployment funds its solver out of band; set SOLVER_PROVISION_ENABLED=false and the ladder
# config falls back to the branch's in-repo default.

# Consumed by log() in the sourced prelude, which shellcheck cannot see from here.
# shellcheck disable=SC2034
ROLE=solver-provision
# shellcheck source=images/offerfiles-kernel/entrypoint-common.sh
. /usr/local/lib/offerfiles/entrypoint-common.sh

unset_if_empty SOLVER_LADDER_CONFIG

require_env MIDNIGHT_NETWORK_ID MIDNIGHT_NODE_HTTP MIDNIGHT_INDEXER_HTTP \
            MIDNIGHT_INDEXER_WS MIDNIGHT_PROOF_SERVER_URL SOLVER_SEED \
            SOLVER_LADDER_CONFIG

LADDER_DIR="$(dirname "${SOLVER_LADDER_CONFIG}")"
MARKER="${LADDER_DIR}/.provisioned"
IN_REPO_LADDER="${REPO_ROOT}/packages/solver/config/ladders.dev.json"

mkdir -p "${LADDER_DIR}"

# The solver reads SOLVER_LADDER_CONFIG unconditionally, so this script must leave a readable
# file behind on EVERY path it can exit through — including the disabled one. A missing file
# would surface as a solver crash loop whose cause is three services away.
fallback_ladder() {
  if [ ! -f "${SOLVER_LADDER_CONFIG}" ]; then
    install -m 0644 "${IN_REPO_LADDER}" "${SOLVER_LADDER_CONFIG}"
    log "installed the branch's in-repo dev ladder at ${SOLVER_LADDER_CONFIG}"
    log "NOTE: its token colours are from an older deployment and will NOT match this stack's"
  fi
}

if [ "${SOLVER_PROVISION_ENABLED:-true}" != "true" ]; then
  log "SOLVER_PROVISION_ENABLED=${SOLVER_PROVISION_ENABLED:-} — not provisioning the solver"
  log "NOTE: an unfunded solver publishes an EMPTY ladder and the stack still reports healthy"
  fallback_ladder
  exit 0
fi

# Idempotent for the same reason the contract deploy is: a re-run would mint a second tranche
# of inventory and re-fund NIGHT on every restart, turning `docker compose restart` into
# several minutes of proving.
if [ -f "${MARKER}" ] && [ -f "${SOLVER_LADDER_CONFIG}" ]; then
  log "JOIN: ${MARKER} exists — the solver is already provisioned, not minting again"
  log "$(cat "${MARKER}")"
  exit 0
fi

wait_node_block "${MIDNIGHT_NODE_HTTP}" 1 "${NODE_BLOCK_TIMEOUT_S:-600}" \
  || die "midnight-node produced no block"
wait_http "${MIDNIGHT_INDEXER_HTTP}" "indexer" "${INDEXER_WAIT_TIMEOUT_S:-300}" \
  || die "the indexer never answered"
wait_http "${MIDNIGHT_PROOF_SERVER_URL}" "proof-server" "${PROOF_WAIT_TIMEOUT_S:-300}" \
  || die "the proof server never answered"

# The mint is a contract call, so this needs the deployed contract's identity.
adopt_contract_address

# ── the genesis-1 facade mutex (00011 Q7) ────────────────────────────────────
# bootstrap-dev.ts funds the solver's NIGHT from GENESIS before it mints, so this one-shot
# drives a facade on the same seed `maker-offer` posts from and `poster-provision` funds
# from. The first two are ordered by `depends_on` inside this fragment; the third lives in
# compose/poster.yml, which `depends_on` cannot reach across — a dependency on a service
# outside the merged set does not render, and `--with poster` WITHOUT `--with solver` is a
# supported combination. So all three take this lock instead. See take_genesis_lock() in
# images/offerfiles-kernel/entrypoint-common.sh.
take_genesis_lock

cd "${REPO_ROOT}" || die "no ${REPO_ROOT}"
log "provisioning the solver wallet (bootstrap-dev.ts) — mints BOTH sides of the pair"
if bun run packages/solver/scripts/bootstrap-dev.ts; then
  date -u +%Y-%m-%dT%H:%M:%SZ > "${MARKER}"
  log "solver provisioned; marker written to ${MARKER}"
  exit 0
fi

# FAIL LOUDLY. This is NOT the deploy one-shot's non-fatal mint: without solver inventory the
# stack comes up healthy and quotes nothing, which is the one outcome this service exists to
# prevent.
log "ERROR: bootstrap-dev.ts failed — the solver would publish an EMPTY ladder."
log "ERROR: refusing to report success; the cause is in the log above."
exit 1
