#!/usr/bin/env bash
# issuer-registry — validate and DUMP this stack's published registry. READ-ONLY.
#
#   docker compose run --rm --no-deps issuer-registry
#   docker compose run --rm --no-deps -e ISSUER_REGISTRY_JSON=1 issuer-registry
#
# What it is for: `scripts/verify-issuer.sh` asserts on its output, `docs/OPERATIONS.md` gives
# an operator the same command to see the six ids and decimals, and `entrypoint-deploy.sh` and
# `entrypoint-registrar.sh` both run the underlying script so that "the registry is valid" is
# checked by ONE implementation in three places.
#
# It touches no chain and needs no seed: `--no-deps` is enough, and it is the cheapest possible
# answer to "what tokens does this stack have?".
#
# Optionally it also runs the pinned repository's OWN read-only on-chain verification
# (`npm run verify:v1`), which re-checks every verifier key against chain state, the immutable
# metadata, the derived token id, the artifact digest, the recorded source revision and the
# deploy action at the recorded height. That needs the node and the indexer, takes minutes, and
# is therefore opt-in: ISSUER_VERIFY_ONCHAIN=1.

# Consumed by log() in the sourced prelude, which shellcheck cannot see from here.
# shellcheck disable=SC2034
ROLE=issuer-registry
# shellcheck source=images/issuer/entrypoint-common.sh
. /usr/local/lib/issuer/entrypoint-common.sh

export MN_NETWORK="${MN_NETWORK:-undeployed}"
export MN_METADATA_OUTPUT_DIR="${ISSUER_REGISTRY_DIR}"

cd "${REPO_ROOT}" || die "no ${REPO_ROOT}"

log "registry ${ISSUER_REGISTRY_FILE}"
RC=0
node --import tsx "${REPO_ROOT}/m1/registry.ts" || RC=$?

if [ "${RC}" -eq 0 ] && [ "${ISSUER_VERIFY_ONCHAIN:-}" = "1" ]; then
  require_env MN_NODE_URL MN_INDEXER_URL MN_INDEXER_WS_URL
  log "ISSUER_VERIFY_ONCHAIN=1 — running the pinned repository's own read-only verification"
  log "  npm run verify:v1   (node --import tsx scripts/v1-deploy.ts verify)"
  START="$(date +%s)"
  timeout -k 30 "${ISSUER_VERIFY_TIMEOUT_S:-1800}" npm run --silent verify:v1 || RC=$?
  log "verify:v1 exited ${RC} after $(( $(date +%s) - START ))s"
fi

exit "${RC}"
