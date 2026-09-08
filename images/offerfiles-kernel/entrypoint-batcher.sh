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
# SINCE 00020 PR C IT WAITS ON NOTHING BUT THE CHAIN. It used to depend on
# `offerfiles-deploy` in compose, and that was never an address dependency: it was the
# wallet-serialisation rule, because the deleted faucet contract's mint drove a genesis-1
# facade inside that one-shot. Kernel #69 removed the contract and the mint, this repository
# retired the one-shot with them, and the genesis facade is now serialised by the `flock` on
# the shared `genesis-lock` volume among the one-shots that actually take it — none of which
# is this service. The batcher holds its own dedicated seed (…0003) and collides with nothing.
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
