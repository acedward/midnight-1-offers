#!/usr/bin/env bash
# offerfiles-deploy — the ONE-SHOT that gives this stack its contract identity.
#
# THE BUG THIS SERVICE EXISTS TO PREVENT. The kernel repository's `midnight-contract:deploy`
# is literally `midnight-contract:clean && bun run deploy.ts`, and clean is
# `rm -rf midnight-level-db-deploy && rm -f contract.json contract-offer-files.<network>.json`.
# Run it on every container start — which is what an orchestrated or self-deploying kernel
# does — and every `docker compose up -d --force-recreate` DELETES the address and mints a
# brand-new contract. The order book's identity resets under it, silently, and only shows up
# much later as offers that cannot be found. The 2.x sibling measured three different
# addresses in one day before splitting the deploy out exactly like this.
#
# So: THIS IS THE ONLY DEPLOYER IN THE STACK. `restart: "no"`, and every other offer-files
# service waits on `service_completed_successfully`.
#
# Two properties carry the whole design:
#
#   IDEMPOTENCE — the presence of the address file on the shared volume IS the
#   "already deployed" flag. A container that finds one JOINS that deployment and exits 0
#   without deploying. Forcing a redeploy is a deliberate act: drop the volume, or
#   `./down.sh -v`.
#
#   ATOMIC PUBLICATION, ADDRESS BEFORE TOKENS — each artifact is written to a temp file on
#   the same volume and `mv`d into place, so a reader never sees a half-written file. The
#   address is published BEFORE the mint runs, so a mint failure cannot strand a stack that
#   already has a perfectly good contract on chain.

# Consumed by log() in the sourced prelude, which shellcheck cannot see from here.
# shellcheck disable=SC2034
ROLE=deploy
# shellcheck source=images/offerfiles-kernel/entrypoint-common.sh
. /usr/local/lib/offerfiles/entrypoint-common.sh

require_env MIDNIGHT_NETWORK_ID MIDNIGHT_STORAGE_PASSWORD \
            MIDNIGHT_NODE_HTTP MIDNIGHT_INDEXER_HTTP MIDNIGHT_INDEXER_WS \
            MIDNIGHT_PROOF_SERVER_URL

load_celestia_env

PUBLISHED="${CONTRACT_SHARE_DIR}/${CONTRACT_FILE}"
PUBLISHED_MINTED="${CONTRACT_SHARE_DIR}/${MINTED_FILE}"

mkdir -p "${CONTRACT_SHARE_DIR}"

if [ -f "${PUBLISHED}" ]; then
  log "JOIN: ${PUBLISHED} already exists — NOT deploying a second contract"
  log "$(tr -d '\n ' < "${PUBLISHED}")"
  log "(./down.sh -v, or dropping the offerfiles-deploy volume, forces a redeploy)"
else
  # A deploy proves and submits a real transaction, so all three chain services must be up
  # AND the chain must have produced a block. compose gates on their healthchecks; this
  # re-proves it per container, because a container that comes back after its dependencies
  # moved must not inherit a stale all-clear from bring-up.
  wait_node_block "${MIDNIGHT_NODE_HTTP}" 1 "${NODE_BLOCK_TIMEOUT_S:-600}" \
    || die "midnight-node produced no block"
  wait_http "${MIDNIGHT_PROOF_SERVER_URL}" "proof-server" "${PROOF_WAIT_TIMEOUT_S:-300}" \
    || die "proof-server never answered"
  wait_http "${MIDNIGHT_INDEXER_HTTP}" "indexer" "${INDEXER_WAIT_TIMEOUT_S:-300}" \
    || die "indexer never answered"

  log "no persisted contract for network ${NETWORK_ID} — deploying"
  cd "${CONTRACT_TARGET_DIR}" || die "no ${CONTRACT_TARGET_DIR}"
  # The deploy's LevelDB private-state store is encrypted with MIDNIGHT_STORAGE_PASSWORD. It
  # is container-local and transient: only the ADDRESS outlives this container.
  bun run midnight-contract:deploy || die "midnight-contract:deploy failed"

  LOCAL_CONTRACT="${CONTRACT_TARGET_DIR}/${CONTRACT_FILE}"
  [ -f "${LOCAL_CONTRACT}" ] \
    || die "the deploy reported success but wrote no ${CONTRACT_FILE}"

  TMP="${CONTRACT_SHARE_DIR}/.${CONTRACT_FILE}.$$"
  cp "${LOCAL_CONTRACT}" "${TMP}"
  mv -f "${TMP}" "${PUBLISHED}"
  log "published ${PUBLISHED}: $(tr -d '\n ' < "${PUBLISHED}")"
fi

# Present on BOTH paths, including the JOIN path: the mint script and `readMidnightContract()`
# read the file from the package directory, not from the volume.
install -m 0644 "${PUBLISHED}" "${CONTRACT_TARGET_DIR}/${CONTRACT_FILE}"

# ── mint the dev test tokens — riding this one-shot, and NON-FATAL ───────────
# A mint hiccup must not tear the stack down: the contract exists, the book works, and
# everything downstream is blocked on this container's exit status. It is tracked by its own
# marker rather than by the contract artifact, so a failed mint retries on the next start
# WITHOUT re-deploying the contract.
if [ -f "${MINT_MARKER}" ]; then
  log "dev test tokens already minted for this stack — skipping"
  exit 0
fi

log "minting dev test tokens (non-fatal)"
cd "${CONTRACT_TARGET_DIR}" || die "no ${CONTRACT_TARGET_DIR}"
MINT_LOG="$(mktemp)"
if bun run mint-test-tokens.ts 2>&1 | tee "${MINT_LOG}"; then
  date -u +%Y-%m-%dT%H:%M:%SZ > "${MINT_MARKER}"
  log "mint complete; marker written"

  # ── publish the minted COLOURS, not merely the fact that minting happened ──
  # A token's colour is derived from the DEPLOYED CONTRACT ADDRESS plus a domain separator,
  # so it is different on every fresh stack and cannot be written down anywhere in advance.
  # `mint-test-tokens.ts` only prints it. Anything downstream that has to name a token — the
  # verify script's known-tokens assertion, a maker offer, an operator reading the book —
  # would otherwise have to scrape container logs, which stop existing the moment this
  # one-shot is pruned. So it is published next to the address, atomically and by the same
  # rule: the address file is this stack's identity and these colours are part of it.
  if MINTED_JSON="$(grep -o '{"shielded.*}' "${MINT_LOG}" | tail -1)" && [ -n "${MINTED_JSON}" ]; then
    TMP_MINTED="${CONTRACT_SHARE_DIR}/.${MINTED_FILE}.$$"
    printf '%s\n' "${MINTED_JSON}" > "${TMP_MINTED}"
    mv -f "${TMP_MINTED}" "${PUBLISHED_MINTED}"
    log "published ${PUBLISHED_MINTED}: ${MINTED_JSON}"
  else
    log "WARNING: could not extract the MINTED line — ${PUBLISHED_MINTED} not written"
    log "WARNING: anything downstream that names a token must be given its colour explicitly"
  fi
else
  log "WARNING: mint-test-tokens failed — continuing (non-fatal). It retries on the next start."
fi
rm -f "${MINT_LOG}"

exit 0
