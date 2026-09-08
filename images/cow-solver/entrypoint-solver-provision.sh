#!/usr/bin/env bash
# solver-provision — give the solver something to trade with, then let UPSTREAM'S OWN CHECK
# say whether it worked. ONE-SHOT, MANDATORY.
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
# ── WHAT IT RAN UP TO KERNEL_REF=a608fa6…, AND WHY THAT IS GONE (00020 PR C) ─
# `packages/solver/scripts/bootstrap-dev.ts`. That script used to fund the solver's NIGHT from
# genesis, register it for DUST, MINT the solver both test colours through the same faucet
# circuit the kernel's `mint-test-tokens.ts` used, and write those colours into the ladder.
#
# It still exists at `e3b9388…` and it does none of that any more. Read at the pin, it is now
# a CHECK: it requires `SOLVER_TOKEN_A`/`SOLVER_TOKEN_B` as 64-hex colours of "an externally
# issued token", refuses unless the wallet already holds at least 1 000 000 base units of each
# ("local minting is unavailable"), refuses unless it already holds NIGHT ("no local funding
# fallback runs"), and writes a ladder naming the pair `TESTA`/`TESTB`.
#
# ── AND WHY THIS SCRIPT RUNS provision-solver-fees.ts INSTEAD ────────────────
# `deploy/scripts/provision-solver-fees.ts` is the same check one step further on, and it is
# the one UPSTREAM'S OWN deployment runs (`deploy/compose.yml`'s `solver-provision`, behind
# `SOLVER_PROVISION_TOKEN_IN`/`_OUT`). Two differences decide it:
#
#   * it writes a machine-readable RECEIPT (`SOLVER_PROVISION_RECEIPT`) carrying
#     `mode: "external-prefunded"`, `inventorySource: "external"` and `dustReady`, measured on
#     the solver's own wallet by the only process entitled to open that facade. The kernel's
#     canonical settlement driver asserts on exactly those fields — "no tokens were
#     provisioned here" has to be an OBSERVATION, not a configuration claim — and
#     `bootstrap-dev.ts` writes no receipt at all;
#   * its ladder names the pair `TOKEN_IN`/`TOKEN_OUT`, which is what the pinned deployment's
#     own tooling and scripts/verify-solver.sh read.
#
# The rungs are IDENTICAL in both and they are FIXED BASE-UNIT LEVELS —
# {1000→1000, 100000→99000, 1000000→970000}, `refPricesUsd` "1" on both sides — so they are
# NOT scaled by a token's decimals. scripts/verify-solver.sh asserts those three numbers.
#
# ── WHAT THIS SCRIPT ADDS ON TOP, AND WHY ───────────────────────────────────
# `provision-solver-fees.ts` REFUSES when the wallet has no NIGHT: "Prefund it externally on
# undeployed; this deployment cannot fund the wallet". That is the right stance for a
# deployment aimed at a public network and the wrong one for m1, whose contract is that
# `./up.sh` on a clean host with NO `.env` reaches a working stack. So this one-shot funds the
# NIGHT first, with the same `night-provision.ts` that funds the poster and the maker, and
# THEN runs upstream's check on top of it. This deployment supplies the inventory; upstream's
# script verifies it — which is the division of labour kernel #69 asks for.
#
# THE SWAP-TOKEN INVENTORY IS NOT THIS SCRIPT'S JOB. It comes from `solver-inventory`, a
# one-shot on the ISSUER image (compose/solver.yml), because that is the only image in the
# stack carrying the token contracts. It is ordered AFTER this service — both open a facade on
# SOLVER_SEED, and one facade per seed is an SDK rule.
#
# ORDERING IS LOAD-BEARING, twice over:
#   1. it drives a wallet on SOLVER_SEED, so the solver must not be running and
#      `solver-inventory` must not be running: compose gates both on this service's
#      `service_completed_successfully`;
#   2. it drives the GENESIS wallet, as do `poster-provision`, `maker-provision` and
#      `issuer-deploy` in two other fragments, so it takes the `flock` on the shared
#      `genesis-lock` volume (00011 Q7).
#
# DEVNET ONLY. This moves genesis NIGHT to a public dev seed on a throwaway chain. A real
# deployment funds its solver out of band; set SOLVER_PROVISION_ENABLED=false and the ladder
# config falls back to the branch's in-repo default.

# Consumed by log() in the sourced prelude, which shellcheck cannot see from here.
# shellcheck disable=SC2034
ROLE=solver-provision
# shellcheck source=images/offerfiles-kernel/entrypoint-common.sh
. /usr/local/lib/offerfiles/entrypoint-common.sh

unset_if_empty SOLVER_LADDER_CONFIG SOLVER_PROVISION_RECEIPT

require_env MIDNIGHT_NETWORK_ID MIDNIGHT_NODE_HTTP MIDNIGHT_INDEXER_HTTP \
            MIDNIGHT_INDEXER_WS MIDNIGHT_PROOF_SERVER_URL SOLVER_SEED \
            SOLVER_LADDER_CONFIG

LADDER_DIR="$(dirname "${SOLVER_LADDER_CONFIG}")"
MARKER="${LADDER_DIR}/.provisioned"
IN_REPO_LADDER="${REPO_ROOT}/packages/solver/config/ladders.dev.json"
export SOLVER_PROVISION_RECEIPT="${SOLVER_PROVISION_RECEIPT:-${LADDER_DIR}/provision-receipt.json}"

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

# Idempotent for the same reason every other one-shot here is: a re-run would send another
# 2e13 NIGHT and re-prove the DUST registration on every `docker compose restart`.
if [ -f "${MARKER}" ] && [ -f "${SOLVER_LADDER_CONFIG}" ]; then
  log "JOIN: ${MARKER} exists — the solver is already provisioned, not funding again"
  log "$(tr '\n' ' ' < "${MARKER}")"
  exit 0
fi

# ── the two token ids ───────────────────────────────────────────────────────
# Configured as NAMES (`TWBTC`/`TWETH`) and translated to this chain's 64-hex ids through the
# issuer's handoff; a raw 64-hex value passes through untouched. `provision-solver-fees.ts`
# validates both against /^[0-9a-f]{64}$/, refuses them equal, and refuses NIGHT as a swap leg
# — so a name reaching it unresolved would fail with a message about a value nobody typed.
require_env SOLVER_PROVISION_TOKEN_IN SOLVER_PROVISION_TOKEN_OUT
resolve_token_leg SOLVER_PROVISION_TOKEN_IN
resolve_token_leg SOLVER_PROVISION_TOKEN_OUT

wait_node_block "${MIDNIGHT_NODE_HTTP}" 1 "${NODE_BLOCK_TIMEOUT_S:-600}" \
  || die "midnight-node produced no block"
wait_http "${MIDNIGHT_INDEXER_HTTP}" "indexer" "${INDEXER_WAIT_TIMEOUT_S:-300}" \
  || die "the indexer never answered"
wait_http "${MIDNIGHT_PROOF_SERVER_URL}" "proof-server" "${PROOF_WAIT_TIMEOUT_S:-300}" \
  || die "the proof server never answered"

cd "${REPO_ROOT}" || die "no ${REPO_ROOT}"

# ── step 1: NIGHT from genesis ──────────────────────────────────────────────
# `night-provision.ts` lives OUTSIDE /app so the image's kernel tree stays exactly the pinned
# commit (00011 Q12), and bun resolves a BARE specifier by walking up from the IMPORTING file
# — so it is installed into /app/.m1 at runtime, where /app/node_modules is on the way up.
# Same mechanism as images/offerfiles-kernel/entrypoint-night-provision.sh; the two differ
# only in that this one goes on to run upstream's check in the same container.
RUN_DIR="${REPO_ROOT}/.m1"
install -d -m 0755 "${RUN_DIR}"
install -m 0644 /usr/local/lib/offerfiles/night-provision.ts "${RUN_DIR}/night-provision.ts"

take_genesis_lock

log "funding the solver wallet with NIGHT from genesis (transfer + confirmation, ~1-2 min)"
NIGHT_LOG="${LADDER_DIR}/.last-night-provision-solver.log"
NIGHT_RC=0
M1_NIGHT_ROLE="solver" \
M1_NIGHT_RECIPIENT_SEED="${SOLVER_SEED}" \
  bun run "${RUN_DIR}/night-provision.ts" 2>&1 | tee "${NIGHT_LOG}" || NIGHT_RC=$?

release_genesis_lock

if [ "${NIGHT_RC}" -ne 0 ]; then
  log "ERROR: the solver wallet was NOT funded with NIGHT, so upstream's prefunding check"
  log "ERROR: would refuse ('SOLVER_SEED has no NIGHT') and the solver would publish an EMPTY"
  log "ERROR: ladder. The cause is in the log above."
  exit "${NIGHT_RC}"
fi

# `|| true` on every extraction: a legitimately absent line must yield an empty string, never a
# `pipefail` exit that kills this script from inside `$( )` (00011 C.8).
NIGHT_RESULT="$(grep -m1 '^NIGHT_PROVISION_RESULT ' "${NIGHT_LOG}" || true)"

# ── step 2: upstream's own external-prefunding check ────────────────────────
# It registers the NIGHT just delivered for DUST (`ensureSolverDustReady`), reads the solver's
# balances, writes the ladder for the explicit pair and writes the receipt the settlement
# driver asserts on. It never funds, transfers, deploys or mints anything.
log "running upstream's external-prefunding check (deploy/scripts/provision-solver-fees.ts)"
if bun run deploy/scripts/provision-solver-fees.ts; then
  {
    date -u +%Y-%m-%dT%H:%M:%SZ
    printf 'mode=external-prefunded tokenIn=%s tokenOut=%s\n' \
      "${SOLVER_PROVISION_TOKEN_IN}" "${SOLVER_PROVISION_TOKEN_OUT}"
    if [ -n "${NIGHT_RESULT}" ]; then printf '%s\n' "${NIGHT_RESULT}"; fi
  } > "${MARKER}"
  log "solver provisioned; ladder ${SOLVER_LADDER_CONFIG}, receipt ${SOLVER_PROVISION_RECEIPT}"
  log "NOTE: the SWAP-TOKEN inventory is minted next, by the \`solver-inventory\` one-shot on"
  log "NOTE: the issuer image — this script deliberately funds NIGHT and nothing else."
  exit 0
fi

# FAIL LOUDLY. Without a ladder the stack comes up healthy and quotes nothing, which is the one
# outcome this service exists to prevent.
log "ERROR: provision-solver-fees.ts failed — the solver would publish an EMPTY ladder."
log "ERROR: refusing to report success; the cause is in the log above."
exit 1
