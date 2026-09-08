#!/usr/bin/env bash
# issuer-fund — MINT AN EXACT AMOUNT OF ONE ISSUER TOKEN TO ONE WALLET, HEADLESSLY.
#
#   docker compose run --rm issuer-fund <TOKEN> <base-units> <recipient-seed>
#
#   docker compose run --rm issuer-fund TWBTC 100000000 \
#       0000000000000000000000000000000000000000000000000000000000000032
#   docker compose run --rm issuer-fund twETH 5000000000000000000 @/run/secrets/taker.hex
#
# THIS IS THE FUNDING PRIMITIVE the rest of the stack calls. `solver-provision`,
# `maker-offer`, `poster-provision`, the e2e driver and the shielded-night book chain all need
# a specific amount of a specific token in a specific wallet, and none of them can mint any
# more (kernel #69 removed the faucet contract). They call this.
#
# ── THE CLI ─────────────────────────────────────────────────────────────────
#   $1  TOKEN        the kernel's name (TWBTC) or the registry's symbol (twBTC) —
#                    case-insensitive, one of the six in this stack's registry.
#   $2  base-units   plain decimal digits, positive, < 2^64. NOT whole coins: twBTC has 8
#                    decimals so one coin is 100000000, and twETH has 18 so one coin is
#                    1000000000000000000. Stated in base units because that is the only
#                    spelling that is exact for every token, and because the contract's own
#                    `mint` takes a Uint<64> of base units.
#   $3  recipient    a 64/128-hex master seed, or `@<path>` to read one out of a file. The
#                    file form keeps a seed out of `docker inspect` and out of compose's own
#                    echo of the command; the inline form is what this repository's public
#                    devnet roster makes convenient.
#
# Each argument may instead be given as ISSUER_FUND_TOKEN / ISSUER_FUND_AMOUNT /
# ISSUER_FUND_SEED, which is how a compose one-shot with a fixed job states it.
#
# ── EXIT CODES (the contract for every caller) ──────────────────────────────
#   0   minted, and the recipient's balance for that colour moved by EXACTLY the amount
#   78  EX_CONFIG — a missing or malformed argument, an unknown token, no registry yet
#   1   the mint failed, or the balance did not move by exactly the amount
#
# ── THE RECEIPT (one line on stdout; a caller may grep it) ──────────────────
#   ISSUER_FUND_RESULT token=TWBTC symbol=twBTC tokenId=<64 hex> privacy=shielded decimals=8
#                      amount=100000000 recipient=…0032 tx=<hash> balanceBefore=0
#                      balanceAfter=100000000 delta=100000000 verified=true
#
# ── ONE FACADE PER SEED, ENFORCED ──────────────────────────────────────────
# This command opens a wallet facade on the ISSUER's seed (…0051) to pay for and submit the
# mint, and one on the RECIPIENT's seed to read the balance back. Two facades on one seed
# against one Midnight node force each other's connection down with no error naming the cause
# (wallets/wallets.json), so:
#
#   * it holds a `flock` on the `issuer-state` volume, which `issuer-deploy` also holds, so a
#     fund call cannot run while the deploy runner has the issuer wallet open — nor two fund
#     calls at once;
#   * it REFUSES (exit 78) if the recipient seed IS the issuer seed;
#   * the CALLER is responsible for the recipient: fund a wallet BEFORE the long-lived service
#     that owns it starts. Every provisioning one-shot in this stack is already gated that way
#     by compose (`service_completed_successfully`).
#
# ── DUST ────────────────────────────────────────────────────────────────────
# A mint is a proving transaction and is paid for in DUST from the issuer's registered NIGHT.
# `issuer-deploy` funds and registers that NIGHT once per chain; if it has not run, this
# command says so in one line instead of failing inside the SDK.

# Consumed by log() in the sourced prelude, which shellcheck cannot see from here.
# shellcheck disable=SC2034
ROLE=issuer-fund
# shellcheck source=images/issuer/entrypoint-common.sh
. /usr/local/lib/issuer/entrypoint-common.sh

usage() {
  log "usage: issuer-fund <TOKEN> <base-units> <recipient-seed|@file>"
  log "   or: ISSUER_FUND_TOKEN=… ISSUER_FUND_AMOUNT=… ISSUER_FUND_SEED=… issuer-fund"
  log "TOKEN is one of the six in this stack's registry; run"
  log "  docker compose run --rm --no-deps issuer-registry"
  log "to list them with their ids and decimals."
}

# Positional arguments win over the environment: a `docker compose run --rm issuer-fund A B C`
# is the interactive form, and an operator's arguments must not be silently overridden by an
# environment default baked into the fragment.
TOKEN_ARG="${1:-${ISSUER_FUND_TOKEN:-}}"
AMOUNT_ARG="${2:-${ISSUER_FUND_AMOUNT:-}}"
SEED_ARG="${3:-${ISSUER_FUND_SEED:-}}"

if [ -z "${TOKEN_ARG}" ] || [ -z "${AMOUNT_ARG}" ] || [ -z "${SEED_ARG}" ]; then
  log "missing argument(s): token='${TOKEN_ARG}' amount='${AMOUNT_ARG}' seed=$([ -n "${SEED_ARG}" ] && printf 'set' || printf 'MISSING')"
  usage
  exit 78
fi

case "${AMOUNT_ARG}" in
  ''|*[!0-9]*)
    log "the amount must be plain decimal BASE UNITS, got '${AMOUNT_ARG}'"
    log "(twBTC has 8 decimals, so one whole coin is 100000000; twETH has 18)"
    exit 78
    ;;
esac

require_env MN_NODE_URL MN_NODE_WS_URL MN_INDEXER_URL MN_INDEXER_WS_URL MN_PROOF_SERVER_URL \
            ISSUER_SEED

MN_NETWORK="${MN_NETWORK:-undeployed}"
if [ "${MN_NETWORK}" != "undeployed" ]; then
  log "REFUSING to run with MN_NETWORK=${MN_NETWORK} — this image mints with a PUBLIC devnet seed"
  exit 78
fi
export MN_NETWORK
export MN_METADATA_OUTPUT_DIR="${ISSUER_REGISTRY_DIR}"

[ -f "${ISSUER_REGISTRY_FILE}" ] || {
  log "no registry at ${ISSUER_REGISTRY_FILE}"
  log "run the issuer-deploy one-shot first: docker compose run --rm issuer-deploy"
  exit 78
}

# ── the recipient seed: inline, or @file ────────────────────────────────────
# `@path` reads the file's contents into the same tmpfs the issuer's seed goes to, so the code
# below has exactly one shape to handle and the ORIGINAL file is never re-read (and never
# needs to be writable, or on the same filesystem).
case "${SEED_ARG}" in
  @*)
    RECIPIENT_FILE="${SEED_ARG#@}"
    [ -r "${RECIPIENT_FILE}" ] || { log "cannot read the recipient seed file ${RECIPIENT_FILE}"; exit 78; }
    ISSUER_FUND_RECIPIENT_SEED="$(tr -d '[:space:]' < "${RECIPIENT_FILE}")"
    ;;
  *)
    ISSUER_FUND_RECIPIENT_SEED="${SEED_ARG}"
    ;;
esac
export ISSUER_FUND_RECIPIENT_SEED

MN_SEED_FILE="$(write_seed_file ISSUER_SEED issuer.hex)" || exit 78
MN_RECIPIENT_SEED_FILE="$(write_seed_file ISSUER_FUND_RECIPIENT_SEED recipient.hex)" || exit 78
export MN_SEED_FILE MN_RECIPIENT_SEED_FILE
# The seed itself must not stay in the environment of the node process: it has a FILE now, and
# the file is the interface the pinned tree accepts.
unset ISSUER_FUND_RECIPIENT_SEED

export ISSUER_FUND_TOKEN="${TOKEN_ARG}"
export ISSUER_FUND_AMOUNT="${AMOUNT_ARG}"

cd "${REPO_ROOT}" || die "no ${REPO_ROOT}"

# The chain has to be transactable, not merely answering: a mint proves and submits.
wait_for_stack

# ONE FACADE ON THE ISSUER SEED AT A TIME (see the header). Taken AFTER the readiness waits so
# a queue of fund calls does not hold the lock while the stack is still coming up.
take_issuer_lock

# The last four characters of the seed identify the roster wallet (…0032 is e2e-taker) without
# printing a seed. Every record in this repository names a wallet that way.
RECIPIENT_TAIL="$(tail -c 4 "${MN_RECIPIENT_SEED_FILE}")"
log "minting ${ISSUER_FUND_AMOUNT} base units of ${ISSUER_FUND_TOKEN} to the wallet …${RECIPIENT_TAIL}"

# `exec`, so the node process IS this container's PID 1 and a compose `stop` reaches it. The
# `flock` on FD 8 survives the exec (the descriptor is not close-on-exec) and is released when
# that process exits — the one release path an early failure cannot skip.
exec node --import tsx "${REPO_ROOT}/m1/fund.ts"
