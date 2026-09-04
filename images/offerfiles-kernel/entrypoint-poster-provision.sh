#!/usr/bin/env bash
# poster-provision — give the offer poster's dedicated wallet its NIGHT. ONE-SHOT, MANDATORY.
#
# WHY THIS IS A SERVICE AND NOT A README STEP
# -------------------------------------------
# Upstream's poster is funded by hand ("transfer from the genesis wallet", kernel
# deploy/README.md). m1's contract predates this profile and is stricter: `./up.sh --with
# offerfiles --with poster` on a clean host with NO .env must reach a working stack, the way
# `solver-provision` and `shielded-night-deploy` already make that true for their profiles.
#
# The failure a missing step produces here is quiet, which is the other reason. A poster with
# no NIGHT still STARTS and answers `/health` with a 200 — `degraded: insufficient_dust`, on
# purpose, because restarting it would not produce NIGHT. So an unfunded poster looks like a
# healthy poster that simply never mints.
#
# WHAT IT RUNS
# ------------
# `poster-provision.ts` (this image, alongside the entrypoints): four UTXOs of 5e12 NIGHT
# from MIDNIGHT_GENESIS_SEED to POSTER_SEED, then nothing else. The poster REGISTERS THAT
# NIGHT FOR DUST ITSELF at startup, so NIGHT is the only thing anyone has to send it. The
# script's own header records why upstream's `provision-solver-fees.ts` is not reused
# (00011 Q16).
#
# TWO ORDERING RULES, BOTH LOAD-BEARING
# -------------------------------------
#   1. It drives a facade on POSTER_SEED, so `offer-poster` must not be running: compose
#      gates the poster on this service's `service_completed_successfully`.
#   2. It drives the GENESIS facade, and so do `solver-provision`, `maker-offer` and the
#      `offerfiles-deploy` mint. Compose orders it after the deploy one-shot; the other two
#      live in a DIFFERENT fragment, which `depends_on` cannot reach across, so all three
#      take the `flock` on the shared `genesis-lock` volume instead (00011 Q7 — see
#      take_genesis_lock() in entrypoint-common.sh).
#
# DEVNET ONLY. This moves genesis NIGHT to a public dev seed on a throwaway chain.

# Consumed by log() in the sourced prelude, which shellcheck cannot see from here.
# shellcheck disable=SC2034
ROLE=poster-provision
# shellcheck source=images/offerfiles-kernel/entrypoint-common.sh
. /usr/local/lib/offerfiles/entrypoint-common.sh

require_env MIDNIGHT_NETWORK_ID MIDNIGHT_NODE_HTTP MIDNIGHT_INDEXER_HTTP \
            MIDNIGHT_INDEXER_WS MIDNIGHT_PROOF_SERVER_URL \
            POSTER_SEED MIDNIGHT_GENESIS_SEED

STATE_DIR="${POSTER_STATE_DIR:-/var/lib/offer-poster}"
MARKER="${STATE_DIR}/.provisioned"
mkdir -p "${STATE_DIR}"

if [ "${POSTER_PROVISION_ENABLED:-true}" != "true" ]; then
  log "POSTER_PROVISION_ENABLED=${POSTER_PROVISION_ENABLED:-} — not funding the poster"
  log "NOTE: with no NIGHT the poster reports \`degraded: insufficient_dust\` on /health with"
  log "NOTE: a 200 and never mints. Fund ${POSTER_SEED:0:8}… by hand, or unset this."
  exit 0
fi

# Idempotent for the same reason the contract deploy and solver-provision are: a re-run would
# move another 2e13 NIGHT on every `docker compose restart`. The marker lives on the SAME
# volume as the poster's journal, which is what makes "start over" one operation: `./down.sh
# -v` wipes both, and a chain reset therefore always re-funds.
if [ -f "${MARKER}" ]; then
  log "JOIN: ${MARKER} exists — the poster wallet is already funded on this chain"
  log "$(tr '\n' ' ' < "${MARKER}")"
  exit 0
fi

wait_node_block "${MIDNIGHT_NODE_HTTP}" 1 "${NODE_BLOCK_TIMEOUT_S:-600}" \
  || die "midnight-node produced no block"
wait_http "${MIDNIGHT_INDEXER_HTTP}" "indexer" "${INDEXER_WAIT_TIMEOUT_S:-300}" \
  || die "the indexer never answered"
wait_http "${MIDNIGHT_PROOF_SERVER_URL}" "proof-server" "${PROOF_WAIT_TIMEOUT_S:-300}" \
  || die "the proof server never answered"

# Not needed to move NIGHT — but it is what makes the marker say WHICH deployment this
# funding belongs to, and it fails here rather than three services away if the deploy
# one-shot published nothing.
adopt_contract_address

# ── the script has to run from inside /app ───────────────────────────────────
# bun resolves a BARE specifier by walking up from the IMPORTING FILE, so a script sitting in
# /usr/local/lib/offerfiles would look for /usr/local/lib/node_modules and find nothing. The
# same constraint the kernel tree's own out-of-tree drivers have (see the header of
# scripts/driver/take-snight-offer.ts, which is bind-mounted into /app for it).
#
# Installed at RUNTIME rather than COPYd into the image, so the image's /app stays exactly
# the pinned kernel commit plus its compiled Compact artifacts — the same rule that keeps
# faucet-probe.ts outside /app (00011 Q12).
RUN_DIR="${REPO_ROOT}/.m1"
install -d -m 0755 "${RUN_DIR}"
install -m 0644 /usr/local/lib/offerfiles/poster-provision.ts "${RUN_DIR}/poster-provision.ts"

# The genesis facade, serialised against the solver profile's two one-shots.
take_genesis_lock

cd "${REPO_ROOT}" || die "no ${REPO_ROOT}"
log "funding the poster wallet with NIGHT from genesis (transfer + confirmation, ~1-2 min)"

PROVISION_LOG="${STATE_DIR}/.last-provision.log"
PROVISION_RC=0
bun run "${RUN_DIR}/poster-provision.ts" 2>&1 | tee "${PROVISION_LOG}" || PROVISION_RC=$?

release_genesis_lock

if [ "${PROVISION_RC}" -eq 0 ]; then
  # `|| true` on every extraction: a legitimately absent line must yield an empty string,
  # never a `pipefail` exit that kills this script from inside `$( )` (00011 C.8).
  RESULT="$(grep -m1 '^POSTER_PROVISION_RESULT ' "${PROVISION_LOG}" || true)"
  {
    date -u +%Y-%m-%dT%H:%M:%SZ
    echo "contract=${MIDNIGHT_CONTRACT_ADDRESS:-unknown}"
    if [ -n "${RESULT}" ]; then echo "${RESULT}"; fi
  } > "${MARKER}"
  log "poster wallet funded; marker written to ${MARKER}"
  exit 0
fi

# FAIL LOUDLY. Without NIGHT the poster comes up, reports 200 with `degraded`, and never
# posts an offer — the one outcome this service exists to prevent.
log "ERROR: the poster wallet was NOT funded — it would start, report \`degraded:"
log "ERROR: insufficient_dust\` on /health with a 200, and never mint or post anything."
log "ERROR: the cause is in the log above."
exit 1
