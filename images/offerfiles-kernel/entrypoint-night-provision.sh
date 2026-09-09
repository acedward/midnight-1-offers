#!/usr/bin/env bash
# night-provision — give ONE named wallet its unshielded NIGHT from genesis. ONE-SHOT,
# MANDATORY for every profile that uses it.
#
#   compose/poster.yml  poster-provision   M1_NIGHT_ROLE=poster  recipient …0041
#   compose/solver.yml  maker-provision    M1_NIGHT_ROLE=maker   recipient …0031
#
# (The SOLVER's NIGHT is provisioned by images/cow-solver/entrypoint-solver-provision.sh,
# which runs the same `night-provision.ts` and then upstream's own prefunding CHECK on top of
# it — see that file.)
#
# ── WHY THIS IS A SERVICE AND NOT A README STEP ─────────────────────────────
# Upstream funds these wallets by hand ("transfer from the genesis wallet", kernel
# deploy/README.md), and since kernel #69 `provision-solver-fees.ts` REFUSES to run without
# NIGHT rather than sending any. m1's contract is stricter and older than these profiles:
# `./up.sh --with offerfiles --with issuer --with poster` on a clean host with NO .env must
# reach a working stack, the way `shielded-night-deploy` already makes that true for its own.
#
# The failure a missing step produces is quiet, which is the other reason. A poster with no
# NIGHT still STARTS and answers `/health` with a 200 — `degraded`, on purpose, because
# restarting it would not produce NIGHT. So an unfunded poster looks like a healthy poster
# that never posts.
#
# ── IT WAS entrypoint-poster-provision.sh (00020 PR C) ──────────────────────
# One entrypoint, one script, several services differing only in environment. The maker needs
# exactly this now because it stopped being the genesis wallet: genesis-1 was the maker only
# because the deleted faucet contract's mint credited that wallet and no other held a test
# token to give away. With tokens coming from the `issuer` profile the maker gets its own
# roster seed (…0031), and its own NIGHT.
#
# ── WHAT IT RUNS ────────────────────────────────────────────────────────────
# `night-provision.ts` (this image, alongside the entrypoints): four UTXOs of 5e12 NIGHT from
# MIDNIGHT_GENESIS_SEED to M1_NIGHT_RECIPIENT_SEED, then nothing else. Each recipient REGISTERS
# THAT NIGHT FOR DUST ITSELF, so NIGHT is the only thing anyone has to send.
#
# ── TWO ORDERING RULES, BOTH LOAD-BEARING ───────────────────────────────────
#   1. It drives a facade on the RECIPIENT's seed, so the service that owns that wallet must
#      not be running: compose gates that service on this one's
#      `service_completed_successfully`. The ISSUER's inventory one-shot for the same wallet
#      is ordered against it the same way, for the same reason.
#   2. It drives the GENESIS facade, and so do the other NIGHT one-shots and `issuer-deploy`.
#      Compose cannot order across fragments, so all of them take the `flock` on the shared
#      `genesis-lock` volume instead (00011 Q7 — see take_genesis_lock() in
#      entrypoint-common.sh).
#
# ── THE JOB SPEC ────────────────────────────────────────────────────────────
#   M1_NIGHT_ROLE             a label for the log and the marker (`poster`, `maker`)
#   M1_NIGHT_RECIPIENT_SEED   the recipient's 64-hex seed
#   MIDNIGHT_GENESIS_SEED     the funder
#   M1_NIGHT_MARKER           the idempotence marker's path, on the consuming profile's own
#                             volume so that "start over" is ONE operation (`./down.sh -v`)
#   M1_NIGHT_ENABLED          `false` skips the whole thing and says what that means
#
# DEVNET ONLY. This moves genesis NIGHT to a public dev seed on a throwaway chain.

# Consumed by log() in the sourced prelude, which shellcheck cannot see from here.
# shellcheck disable=SC2034
ROLE="night-provision"
# shellcheck source=images/offerfiles-kernel/entrypoint-common.sh
. /usr/local/lib/offerfiles/entrypoint-common.sh

NIGHT_ROLE="${M1_NIGHT_ROLE:-wallet}"
ROLE="night-provision/${NIGHT_ROLE}"

require_env MIDNIGHT_NETWORK_ID MIDNIGHT_NODE_HTTP MIDNIGHT_INDEXER_HTTP \
            MIDNIGHT_INDEXER_WS MIDNIGHT_PROOF_SERVER_URL \
            M1_NIGHT_RECIPIENT_SEED MIDNIGHT_GENESIS_SEED M1_NIGHT_MARKER

MARKER="${M1_NIGHT_MARKER}"
mkdir -p "$(dirname "${MARKER}")"

if [ "${M1_NIGHT_ENABLED:-true}" != "true" ]; then
  log "M1_NIGHT_ENABLED=${M1_NIGHT_ENABLED:-} — not funding the ${NIGHT_ROLE} wallet"
  log "NOTE: with no NIGHT it cannot pay for a proving transaction. The poster reports"
  log "NOTE: \`degraded\` on /health with a 200 and never posts; the maker cannot post an"
  log "NOTE: offer at all. Fund …${M1_NIGHT_RECIPIENT_SEED: -4} by hand, or unset this."
  exit 0
fi

# Idempotent for the same reason every other one-shot here is: a re-run would move another
# 2e13 NIGHT on every `docker compose restart`. The marker lives on the volume the PROFILE
# wipes, which is what makes "start over" one operation — `./down.sh -v` wipes it and the next
# bring-up re-funds a fresh wallet on a fresh chain.
if [ -f "${MARKER}" ]; then
  log "JOIN: ${MARKER} exists — the ${NIGHT_ROLE} wallet is already funded on this chain"
  log "$(tr '\n' ' ' < "${MARKER}")"
  exit 0
fi

wait_node_block "${MIDNIGHT_NODE_HTTP}" 1 "${NODE_BLOCK_TIMEOUT_S:-600}" \
  || die "midnight-node produced no block"
wait_http "${MIDNIGHT_INDEXER_HTTP}" "indexer" "${INDEXER_WAIT_TIMEOUT_S:-300}" \
  || die "the indexer never answered"
wait_http "${MIDNIGHT_PROOF_SERVER_URL}" "proof-server" "${PROOF_WAIT_TIMEOUT_S:-300}" \
  || die "the proof server never answered"

# ── the script has to run from inside /app ───────────────────────────────────
# bun resolves a BARE specifier by walking up from the IMPORTING FILE, so a script sitting in
# /usr/local/lib/offerfiles would look for /usr/local/lib/node_modules and find nothing. The
# same constraint the kernel tree's own out-of-tree drivers have (see the header of
# scripts/driver/take-snight-offer.ts, which is bind-mounted into /app for it).
#
# Installed at RUNTIME rather than COPYd into the image, so the image's /app tree stays exactly
# the pinned kernel commit (00011 Q12).
RUN_DIR="${REPO_ROOT}/.m1"
install -d -m 0755 "${RUN_DIR}"
install -m 0644 /usr/local/lib/offerfiles/night-provision.ts "${RUN_DIR}/night-provision.ts"

# The genesis facade, serialised against every other one-shot that drives it.
take_genesis_lock

cd "${REPO_ROOT}" || die "no ${REPO_ROOT}"
log "funding the ${NIGHT_ROLE} wallet with NIGHT from genesis (transfer + confirmation, ~1-2 min)"

PROVISION_LOG="$(dirname "${MARKER}")/.last-night-provision-${NIGHT_ROLE}.log"
PROVISION_RC=0
M1_NIGHT_ROLE="${NIGHT_ROLE}" \
  bun run "${RUN_DIR}/night-provision.ts" 2>&1 | tee "${PROVISION_LOG}" || PROVISION_RC=$?

release_genesis_lock

if [ "${PROVISION_RC}" -eq 0 ]; then
  # `|| true` on every extraction: a legitimately absent line must yield an empty string,
  # never a `pipefail` exit that kills this script from inside `$( )` (00011 C.8).
  RESULT="$(grep -m1 '^NIGHT_PROVISION_RESULT ' "${PROVISION_LOG}" || true)"
  {
    date -u +%Y-%m-%dT%H:%M:%SZ
    echo "role=${NIGHT_ROLE}"
    if [ -n "${RESULT}" ]; then echo "${RESULT}"; fi
  } > "${MARKER}"
  log "${NIGHT_ROLE} wallet funded; marker written to ${MARKER}"
  exit 0
fi

# FAIL LOUDLY. Without NIGHT the poster comes up, reports 200 with `degraded`, and never posts
# an offer; the maker cannot post at all. Both are outcomes this service exists to prevent.
log "ERROR: the ${NIGHT_ROLE} wallet was NOT funded — it cannot pay for a proving"
log "ERROR: transaction, so it will either report \`degraded\` for ever or refuse to start."
log "ERROR: the cause is in the log above."
exit 1
