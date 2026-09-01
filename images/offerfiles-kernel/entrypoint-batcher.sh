#!/usr/bin/env bash
# batcher — the balancing batcher (Midnight + Celestia targets), alone, on :3334. PID 1.
#
# `exec bun run packages/batcher/batcher.dev.ts`, a single process.
#
# IT GENUINELY STANDS ALONE, which is why it is its own container rather than a second process
# beside the kernel: checked against main, `packages/batcher` reads NO contract address and
# opens NO database connection. Its only state is a FileStorage directory, which compose gives
# it as its own volume — inputs that have been accepted but not yet submitted live there, and
# an input parked mid-retry that vanishes on restart is an unexplained gap in the book.
#
# It still waits on the deploy one-shot in compose, and that is NOT an address dependency: it
# is the wallet-serialisation rule. Two wallet facades bootstrapping against one Midnight node
# force each other's connection down — the second to connect wins and the first silently stops
# syncing — and the mint wallet runs inside that one-shot.
#
# `batcher.dev.ts` throws unless MIDNIGHT_NETWORK_ID=undeployed, so the variable is required
# here rather than defaulted: a container that reached the throw would restart-loop with the
# real message buried in the middle of a log.
#
# NOT SET HERE, DELIBERATELY: `BATCHER_ALLOW_CONTRACT_TX`. That knob belongs to the v9 branch,
# where batcher-sdk 0.200.x added a blank-ledger-state `wellFormed` gate that rejects the
# frontend faucet's `mint_shielded` contract call as "call to non-existant contract". On this
# 0.103.1 line that gate does not exist at all — `validateInput()` is a size cap plus a hex
# check, and the submit path runs balance → sign → finalize → submit with no ledger validation
# in between — so there is nothing to opt out of, and setting the variable would be a comment
# pretending to be configuration.

# Consumed by log() in the sourced prelude, which shellcheck cannot see from here.
# shellcheck disable=SC2034
ROLE=batcher
# shellcheck source=images/offerfiles-kernel/entrypoint-common.sh
. /usr/local/lib/offerfiles/entrypoint-common.sh

require_env MIDNIGHT_NETWORK_ID MIDNIGHT_NODE_HTTP MIDNIGHT_INDEXER_HTTP \
            MIDNIGHT_INDEXER_WS MIDNIGHT_PROOF_SERVER_URL \
            CELESTIA_RPC_URL BATCHER_STORAGE_DIR BATCHER_WALLET_SEED

if [ "${MIDNIGHT_NETWORK_ID}" != "undeployed" ]; then
  log "batcher.dev.ts requires MIDNIGHT_NETWORK_ID=undeployed, got '${MIDNIGHT_NETWORK_ID}'"
  log "(batcher.preview.ts / batcher.mainnet.ts are the variants for the hosted networks)"
  exit 78
fi

load_celestia_env

mkdir -p "${BATCHER_STORAGE_DIR}"

wait_node_block "${MIDNIGHT_NODE_HTTP}" 1 "${NODE_BLOCK_TIMEOUT_S:-600}" \
  || die "midnight-node produced no block"
wait_http "${MIDNIGHT_INDEXER_HTTP}" "indexer" "${INDEXER_WAIT_TIMEOUT_S:-300}" \
  || die "indexer never answered"
wait_http "${MIDNIGHT_PROOF_SERVER_URL}" "proof-server" "${PROOF_WAIT_TIMEOUT_S:-300}" \
  || die "proof-server never answered"
wait_http "${CELESTIA_RPC_URL}" "celestia bridge" "${CELESTIA_WAIT_TIMEOUT_S:-600}" \
  || die "the Celestia DA RPC never answered"

cd "${REPO_ROOT}" || die "no ${REPO_ROOT}"
log "starting the balancing batcher on :${BATCHER_PORT:-3334} (storage ${BATCHER_STORAGE_DIR})"
exec bun run packages/batcher/batcher.dev.ts
