#!/usr/bin/env bash
# issuer-deploy — THE ONE-SHOT THAT GIVES THIS STACK ITS OWN TOKENS.
#
#   docker compose run --rm issuer-deploy        (compose/issuer.yml, profile `issuer`)
#
# Three steps, in this order, and each one is a precondition of the next:
#
#   1. PROVISION  fund the dedicated `issuer` wallet (…0051) with four large NIGHT UTXOs from
#                 genesis-1 under the shared `genesis-lock`, register that NIGHT for DUST, and
#                 wait for DUST to appear.  (m1/provision.ts)
#   2. DEPLOY     `MN_NETWORK=undeployed npm run deploy:v1` — the pinned repository's own
#                 runner deploys the six v1 token contracts, verifies each one on chain and
#                 publishes `metadata.undeployed.json` atomically into the shared registry
#                 directory.
#   3. REPORT     validate the published registry with the tree's own two validators and print
#                 one line per token.  (m1/registry.ts)
#
# ── WHY STEP 1 IS NOT OPTIONAL ──────────────────────────────────────────────
# The upstream runner refuses to submit anything until it sees a synced wallet with strictly
# positive DUST (`scripts/lib/deployment-wallet.ts`), and it asks nothing of a faucet — there
# is no faucet on a `CFG_PRESET=dev` chain. Without step 1 this one-shot fails several minutes
# in, with an error that names DUST and not the missing funding.
#
# ── WHY IT IS SAFE TO RE-RUN, AND WHAT MAKES A SECOND `./up.sh` FREE ────────
# The runner keeps a private RESUME JOURNAL and a private-state store under
# `<repo root>/.local/`, keyed by sha256(registry path + stack identity), where stack identity
# is sha256(chain name + runtime version + genesis hash) read live off the node. On a second
# run against the SAME chain it re-verifies each recorded contract (verifier keys, immutable
# metadata, derived token id, artifact digest, deploy action at the recorded height) and prints
# `[resume] <SYMBOL> <address>` instead of deploying. That is why `.local` is a VOLUME here: on
# a container-local directory every `./up.sh` would deploy six more contracts and orphan every
# coin already minted.
#
# ── AND WHAT MAKES A CHAIN RESET SAFE ───────────────────────────────────────
# `./down.sh -v` wipes the chain AND this profile's two volumes together, so the ordinary reset
# leaves nothing stale. The interesting case is a registry that SURVIVES a chain reset (an
# operator who wiped only the node volume, or a hand-mounted directory): the runner then sees a
# different stack identity, marks the registry `stale`, and REFUSES with an instruction to
# confirm the reset and rerun with `MN_REDEPLOY_STALE=1`. This entrypoint does NOT set that
# variable by default. Posting stale ids to the kernel is the failure this profile exists to
# prevent, and "delete six contracts' worth of identity" is an operator's decision, not a
# bring-up's. `ISSUER_REDEPLOY_STALE=1` passes it through for the operator who has decided.
#
# ── THE SEED RULE (project 00020 question Q5) ───────────────────────────────
# The issuer holds a wallet facade open through six proving deployments. genesis-1 is already
# the faucet, the kernel's MIDNIGHT_WALLET_SEED and the source every other provisioning
# one-shot draws from, so a second facade on it would take one of those offline with no error
# naming the cause. The issuer therefore has its OWN roster seed, `…0051`, assigned to nothing
# else, and m1/provision.ts refuses (exit 78) if the two seeds are equal.

# Consumed by log() in the sourced prelude, which shellcheck cannot see from here.
# shellcheck disable=SC2034
ROLE=issuer-deploy
# shellcheck source=images/issuer/entrypoint-common.sh
. /usr/local/lib/issuer/entrypoint-common.sh

# Every endpoint is stated in compose/issuer.yml; a missing one is a configuration error this
# container must name rather than default to loopback.
require_env MN_NODE_URL MN_NODE_WS_URL MN_INDEXER_URL MN_INDEXER_WS_URL MN_PROOF_SERVER_URL \
            ISSUER_SEED MIDNIGHT_GENESIS_SEED

# `undeployed` and nothing else. Pointing this at preview or preprod would deploy six issuer
# contracts on a network where the canonical ones are already live, with a publicly known dev
# seed paying for it.
MN_NETWORK="${MN_NETWORK:-undeployed}"
if [ "${MN_NETWORK}" != "undeployed" ]; then
  log "REFUSING to run with MN_NETWORK=${MN_NETWORK}."
  log "This image issues test tokens with a PUBLIC devnet seed from wallets/wallets.json onto a"
  log "throwaway local chain. The canonical Preview/Preprod/Stagenet deployments are published"
  log "by effectstream/mint-test-tokens itself; use those."
  exit 78
fi
export MN_NETWORK
export MN_METADATA_OUTPUT_DIR="${ISSUER_REGISTRY_DIR}"

ISSUER_DEPLOY_TIMEOUT_S="${ISSUER_DEPLOY_TIMEOUT_S:-5400}"
MARKER="${ISSUER_STATE_DIR}/.issuer-deployed"

mkdir -p "${ISSUER_REGISTRY_DIR}" || die "cannot create ${ISSUER_REGISTRY_DIR}"
mkdir -p "${ISSUER_STATE_DIR}" || die "cannot create ${ISSUER_STATE_DIR}"

cd "${REPO_ROOT}" || die "no ${REPO_ROOT}"

# The commit this image was built from, printed once. It is also what the runner records in
# every registry record as `artifact.sourceRevision`, so the two can be compared.
ISSUER_COMMIT="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || printf '<unknown>')"
log "mint-test-tokens ${ISSUER_COMMIT}"
log "registry directory ${ISSUER_REGISTRY_DIR}"
log "state directory    ${ISSUER_STATE_DIR}  (resume journal + private state)"

wait_for_stack
HEIGHT="$(node_height || true)"
log "midnight-node is at height ${HEIGHT:-<unreadable>}"

# ── seeds onto the tmpfs ─────────────────────────────────────────────────────
MN_SEED_FILE="$(write_seed_file ISSUER_SEED issuer.hex)" || exit 78
MN_GENESIS_SEED_FILE="$(write_seed_file MIDNIGHT_GENESIS_SEED genesis.hex)" || exit 78
export MN_SEED_FILE MN_GENESIS_SEED_FILE
log "issuer seed written to ${MN_SEED_FILE} (tmpfs, 0600, never logged)"

# ── STEP 1: provision ───────────────────────────────────────────────────────
#
# THE LOCK IS TAKEN AROUND STEP 1 ONLY, and released before the deploy. Step 1 touches
# genesis-1 for well under a minute; step 2 spends many minutes proving on the issuer's own
# wallet, and holding the genesis mutex through it would serialise this profile against
# `solver-provision`, `maker-offer` and `poster-provision` for no reason at all.
#
# The MARKER makes step 1 skippable, but the marker is NOT what makes the whole one-shot
# idempotent — the runner's own resume journal is. The marker exists so a re-run does not
# re-open the contended genesis facade to discover there is nothing to send.
if [ -f "${MARKER}" ]; then
  log "provisioning marker ${MARKER} is present:"
  sed 's/^/      /' "${MARKER}" >&2 || true
  log "skipping the genesis funding step (delete the marker to force it)"
else
  take_genesis_lock
  PROVISION_RC=0
  PROVISION_OUT="$(node --import tsx "${REPO_ROOT}/m1/provision.ts")" || PROVISION_RC=$?
  release_genesis_lock
  if [ "${PROVISION_RC}" -ne 0 ]; then
    die "provisioning the issuer wallet failed (exit ${PROVISION_RC}) — see the log above"
  fi
  RESULT_LINE="$(printf '%s\n' "${PROVISION_OUT}" | grep '^ISSUER_PROVISION_RESULT ' | head -1 || true)"
  [ -n "${RESULT_LINE}" ] || die "the provisioning script printed no ISSUER_PROVISION_RESULT line"
  log "${RESULT_LINE}"
  # Written only after the wallet really holds NIGHT and DUST (the script refuses to print the
  # line otherwise), so a marker can never claim a wallet that got nothing.
  {
    printf 'issuer provisioned on %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'chain height at provisioning: %s\n' "${HEIGHT:-<unreadable>}"
    printf '%s\n' "${RESULT_LINE}"
  } > "${MARKER}"
fi

# ── STEP 2: the repository's own v1 deploy ──────────────────────────────────
#
# Run through the ISSUER FACADE LOCK, not the genesis one: `issuer-fund` holds the same lock,
# so a phase-C provisioning call cannot open a second facade on …0051 while this is deploying.
take_issuer_lock

if [ "${ISSUER_REDEPLOY_STALE:-}" = "1" ]; then
  log "ISSUER_REDEPLOY_STALE=1 — a stale registry will be REPLACED (six new contracts, six new"
  log "colours; every coin minted from the old ones becomes unspendable). This is only correct"
  log "immediately after a deliberate chain reset."
  export MN_REDEPLOY_STALE=1
fi
if [ "${ISSUER_CONFIRM_NO_DEPLOYMENT:-}" = "1" ]; then
  log "ISSUER_CONFIRM_NO_DEPLOYMENT=1 — the operator states that the in-flight deployment the"
  log "journal remembers did NOT finalize. Reconcile the node and indexer before trusting this."
  export MN_CONFIRM_NO_DEPLOYMENT=1
fi

log "deploying the six v1 token contracts (timeout ${ISSUER_DEPLOY_TIMEOUT_S}s)"
log "  npm run deploy:v1   (node --import tsx scripts/v1-deploy.ts deploy)"
DEPLOY_START="$(date +%s)"
DEPLOY_RC=0
# `timeout` rather than an unbounded run: six deployments with proving is the longest single
# operation in this stack, and a hung proof server would otherwise hold a compose bring-up
# open for ever. SIGTERM first, then SIGKILL 60 s later, so the runner's own `finally` can
# close its wallet and leave a reconcilable journal rather than a torn one.
timeout -k 60 "${ISSUER_DEPLOY_TIMEOUT_S}" npm run --silent deploy:v1 || DEPLOY_RC=$?
DEPLOY_SECONDS=$(( $(date +%s) - DEPLOY_START ))

if [ "${DEPLOY_RC}" -ne 0 ]; then
  log "the v1 deploy runner exited ${DEPLOY_RC} after ${DEPLOY_SECONDS}s"
  if [ "${DEPLOY_RC}" -eq 124 ] || [ "${DEPLOY_RC}" -eq 137 ]; then
    log "that is a TIMEOUT (ISSUER_DEPLOY_TIMEOUT_S=${ISSUER_DEPLOY_TIMEOUT_S})."
    log "The runner's private journal keeps an in-flight marker; RECONCILE the chain before"
    log "retrying — see docs/OPERATIONS.md and the runner's own message above."
  fi
  # The registry as it stands, whatever state it is in, because that is the first thing an
  # operator needs. Never fatal on its own.
  if [ -f "${ISSUER_REGISTRY_FILE}" ]; then
    log "the registry file as it now stands:"
    sed -n '1,40p' "${ISSUER_REGISTRY_FILE}" | sed 's/^/      /' >&2 || true
  else
    log "no registry file at ${ISSUER_REGISTRY_FILE}"
  fi
  die "the six token contracts were not deployed"
fi
log "deploy runner finished in ${DEPLOY_SECONDS}s"

# ── STEP 3: validate and report ─────────────────────────────────────────────
#
# The runner already verified every contract on chain before it published — this step is the
# CONSUMER's check: the file this stack will hand to the kernel, the faucet site and every
# funding call is valid against the schema AND the semantic validator, is `ready`, and selects
# six active deployments. `./verify.sh` runs the same script; running it here means a bring-up
# fails at the step that produced the bad file rather than at the one that read it.
REPORT_RC=0
node --import tsx "${REPO_ROOT}/m1/registry.ts" || REPORT_RC=$?
[ "${REPORT_RC}" -eq 0 ] || die "the published registry did not validate (exit ${REPORT_RC})"

# ── STEP 4: publish the shell-sourceable token handoff (00020 PR C) ─────────
#
# Every token-consuming service in this stack runs the KERNEL image, which has no reader for
# `metadata.undeployed.json` and must never grow one — this image's `m1/registry.ts` is the
# single reader, and the one that validates the file two ways. So the ids are projected into
# `${ISSUER_TOKENS_DIR}/tokens.env`, a plain NAME=value file that
# `images/offerfiles-kernel/registry-env.sh` sources.
#
# ON BOTH PATHS, deploy and resume. A `./up.sh` that resumed six existing deployments still
# has to leave the handoff in place: the volume may be new (a fresh `issuer-tokens` volume
# against a kept `issuer-registry` one is exactly what a `./down.sh` without `-v` produces),
# and the file is cheap to rewrite. It is written from the registry that was just validated,
# so a resume cannot publish ids the registry does not carry.
#
# FATAL. Without it the solver, the maker, the poster and the e2e driver have no token ids at
# all, and each would wait out its own timeout and then fail with a message about a missing
# file rather than about the one-shot that should have written it.
TOKENS_ENV_RC=0
node --import tsx "${REPO_ROOT}/m1/tokens-env.ts" || TOKENS_ENV_RC=$?
[ "${TOKENS_ENV_RC}" -eq 0 ] || die "could not publish the token handoff (exit ${TOKENS_ENV_RC})"

log "ISSUER_DEPLOY_RESULT commit=${ISSUER_COMMIT} deploySeconds=${DEPLOY_SECONDS} registry=${ISSUER_REGISTRY_FILE}"
log "the six colours are now in ${ISSUER_REGISTRY_FILE}; the kernel learns them from"
log "issuer-registrar, every kernel-image consumer reads their ids out of"
log "${ISSUER_TOKENS_DIR:-/srv/issuer-tokens}/tokens.env, and automation mints with:"
log "  docker compose run --rm issuer-fund <TOKEN> <base-units> <seed> [count]"
exit 0
