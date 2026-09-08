#!/usr/bin/env bash
# issuer-provision — GIVE ONE WALLET ITS SWAP-TOKEN INVENTORY, once per chain. ONE-SHOT.
#
# The compose-side companion to `issuer-fund`: same primitive, same exactness, but with the
# job stated as ENVIRONMENT rather than as command-line arguments, so a compose service can
# declare "this wallet needs these tokens in these sizes" and be ordered by `depends_on`.
#
# ── WHY THIS EXISTS (00020 PR C) ────────────────────────────────────────────
# Kernel #69 removed the local faucet contract. `solver-provision` no longer funds or mints
# anything, `maker-offer` requires an already-funded wallet, and the offer poster never mints
# at all — it selects one already-spendable coin whose value EQUALS its configured
# `GIVE_AMOUNT`. So somebody has to put real, exactly-sized coins into the solver's, the
# maker's and the poster's wallets BEFORE those services start, and it has to be a container
# in this image because this is the only image that carries the token contracts.
#
# ── THE JOB SPEC ────────────────────────────────────────────────────────────
#   ISSUER_PROVISION_ROLE    a label for the log and the marker (`poster`, `solver`, `maker`)
#   ISSUER_PROVISION_SEED    the RECIPIENT's 64/128-hex seed, or `@<path>`
#   ISSUER_PROVISION_SPEC    whitespace-separated `TOKEN:baseUnits[:count]` entries, e.g.
#                              TWBTC:100000000 TWETH:5000000000000000000
#                              TWBTC:1000000:12          <- TWELVE coins of 1000000
#                            `count` defaults to 1. An empty SPEC is a no-op exit 0, so a
#                            profile can turn its own funding off with one blank variable.
#   ISSUER_PROVISION_MARKER  where the idempotence marker goes. It belongs on the volume the
#                            PROFILE already wipes with `./down.sh -v`, so that "start over"
#                            stays one operation and a chain reset always re-funds.
#
# ── ONE FACADE PER SEED, AND ONE LOCK FOR THE WHOLE JOB ─────────────────────
# Every entry is a separate `m1/fund.ts` run, because each token is a different contract. They
# run SEQUENTIALLY under a SINGLE `flock` on the issuer's facade, taken here rather than once
# per entry: the alternative is releasing and re-acquiring a contended lock between two mints
# for no benefit, and giving another fund call the chance to interleave halfway through a
# wallet's provisioning.
#
# The RECIPIENT's facade is opened by each run too, which is why compose must order this
# one-shot before the long-lived service that owns that wallet — `offer-poster`, `solver` —
# and before any other one-shot that drives the same seed. `service_completed_successfully`
# is how every one of those edges is expressed.
#
# ── IDEMPOTENT, AND HONEST ABOUT WHAT THAT MEANS ────────────────────────────
# The marker records the registry revision and the exact spec it satisfied. A re-run with the
# SAME spec against the SAME registry is a no-op; a re-run with a DIFFERENT spec, or against a
# different registry revision, MINTS AGAIN and says so — because the spec changing is the
# operator asking for different inventory, and a marker that swallowed that would leave a
# poster configured for coins it does not hold.
#
# EXIT CODES: 0 provisioned (or nothing to do); 78 EX_CONFIG; 1 a mint or a read-back failed.

# Consumed by log() in the sourced prelude, which shellcheck cannot see from here.
# shellcheck disable=SC2034
ROLE="issuer-provision"
# shellcheck source=images/issuer/entrypoint-common.sh
. /usr/local/lib/issuer/entrypoint-common.sh

PROVISION_ROLE="${ISSUER_PROVISION_ROLE:-unnamed}"
ROLE="issuer-provision/${PROVISION_ROLE}"
SPEC="${ISSUER_PROVISION_SPEC:-}"
MARKER="${ISSUER_PROVISION_MARKER:-}"

# A blank SPEC is a deliberate "this profile does not want issuer inventory", not a mistake:
# an operator running the poster against a wallet they funded by hand should be able to say so
# with one empty variable. It exits BEFORE any readiness wait, so it costs nothing.
if [ -z "${SPEC//[[:space:]]/}" ]; then
  log "ISSUER_PROVISION_SPEC is empty — not minting any inventory for ${PROVISION_ROLE}"
  log "NOTE: the service that owns this wallet must then find its coins there already, or it"
  log "NOTE: will report an empty inventory (the offer poster: \`degraded: insufficient_inventory\`)."
  exit 0
fi

require_env MN_NODE_URL MN_NODE_WS_URL MN_INDEXER_URL MN_INDEXER_WS_URL MN_PROOF_SERVER_URL \
            ISSUER_SEED ISSUER_PROVISION_SEED

MN_NETWORK="${MN_NETWORK:-undeployed}"
if [ "${MN_NETWORK}" != "undeployed" ]; then
  log "REFUSING to run with MN_NETWORK=${MN_NETWORK} — this image mints with a PUBLIC devnet seed"
  exit 78
fi
export MN_NETWORK
export MN_METADATA_OUTPUT_DIR="${ISSUER_REGISTRY_DIR}"

[ -f "${ISSUER_REGISTRY_FILE}" ] || {
  log "no registry at ${ISSUER_REGISTRY_FILE}"
  log "the issuer-deploy one-shot has not published this chain's tokens yet"
  exit 78
}

# ── the spec, validated BEFORE anything is opened ───────────────────────────
# Every entry checked first, so a typo in the third of four is reported before the first mint
# rather than after it. `|| true` on the extraction: an entry with no third field must yield
# the empty string, never a `pipefail` exit from inside `$( )` (00011 C.8).
SPEC_NORMALISED=""
for entry in ${SPEC}; do
  entry_token="${entry%%:*}"
  entry_rest="${entry#*:}"
  entry_amount="${entry_rest%%:*}"
  case "${entry_rest}" in
    *:*) entry_count="${entry_rest#*:}" ;;
    *)   entry_count=1 ;;
  esac
  if [ -z "${entry_token}" ] || [ "${entry_token}" = "${entry}" ]; then
    log "malformed ISSUER_PROVISION_SPEC entry '${entry}' — expected TOKEN:baseUnits[:count]"
    exit 78
  fi
  case "${entry_amount}" in
    ''|*[!0-9]*) log "entry '${entry}': the amount must be plain decimal BASE UNITS"; exit 78 ;;
  esac
  case "${entry_count}" in
    ''|*[!0-9]*) log "entry '${entry}': the count must be plain decimal digits"; exit 78 ;;
  esac
  if [ "${entry_count}" -lt 1 ] || [ "${entry_count}" -gt 200 ]; then
    log "entry '${entry}': the count must be between 1 and 200"
    exit 78
  fi
  SPEC_NORMALISED="${SPEC_NORMALISED}${entry_token}:${entry_amount}:${entry_count} "
done
SPEC_NORMALISED="${SPEC_NORMALISED% }"

# ── the recipient seed: inline, or @file ────────────────────────────────────
case "${ISSUER_PROVISION_SEED}" in
  @*)
    RECIPIENT_FILE="${ISSUER_PROVISION_SEED#@}"
    [ -r "${RECIPIENT_FILE}" ] || { log "cannot read the recipient seed file ${RECIPIENT_FILE}"; exit 78; }
    ISSUER_FUND_RECIPIENT_SEED="$(tr -d '[:space:]' < "${RECIPIENT_FILE}")"
    ;;
  *)
    ISSUER_FUND_RECIPIENT_SEED="${ISSUER_PROVISION_SEED}"
    ;;
esac
export ISSUER_FUND_RECIPIENT_SEED

MN_SEED_FILE="$(write_seed_file ISSUER_SEED issuer.hex)" || exit 78
MN_RECIPIENT_SEED_FILE="$(write_seed_file ISSUER_FUND_RECIPIENT_SEED recipient.hex)" || exit 78
export MN_SEED_FILE MN_RECIPIENT_SEED_FILE
unset ISSUER_FUND_RECIPIENT_SEED

RECIPIENT_TAIL="$(tail -c 4 "${MN_RECIPIENT_SEED_FILE}")"

# The registry revision is part of the marker's identity: a `./down.sh -v` gives a new chain,
# new contracts and new colours, so inventory minted under the old revision is unspendable.
# `|| true` because an unreadable registry must not kill the script here — it was checked above
# and the mint would fail with a better message.
REGISTRY_REVISION="$(grep -o '"registryRevision"[[:space:]]*:[[:space:]]*"[0-9a-f]*"' \
  "${ISSUER_REGISTRY_FILE}" | grep -o '[0-9a-f]\{64\}' | head -1 || true)"
MARKER_IDENTITY="revision=${REGISTRY_REVISION:-unknown} recipient=…${RECIPIENT_TAIL} spec=${SPEC_NORMALISED}"

if [ -n "${MARKER}" ] && [ -f "${MARKER}" ]; then
  PREVIOUS="$(grep -m1 '^identity ' "${MARKER}" | sed 's/^identity //' || true)"
  if [ "${PREVIOUS}" = "${MARKER_IDENTITY}" ]; then
    log "JOIN: ${MARKER} already records exactly this inventory — not minting again"
    sed 's/^/      /' "${MARKER}" >&2 || true
    exit 0
  fi
  log "the marker records DIFFERENT inventory, so this run will mint:"
  log "  was:  ${PREVIOUS:-<no identity line>}"
  log "  want: ${MARKER_IDENTITY}"
fi

cd "${REPO_ROOT}" || die "no ${REPO_ROOT}"

# The chain has to be transactable, not merely answering: every mint proves and submits.
wait_for_stack

# ONE lock for the WHOLE job — see the header.
take_issuer_lock

STARTED="$(date +%s)"
RECEIPTS=""
for entry in ${SPEC_NORMALISED}; do
  entry_token="${entry%%:*}"
  entry_rest="${entry#*:}"
  entry_amount="${entry_rest%%:*}"
  entry_count="${entry_rest#*:}"
  log "==> ${entry_count} x ${entry_amount} base units of ${entry_token} to …${RECIPIENT_TAIL}"
  FUND_LOG="$(mktemp)"
  FUND_RC=0
  ISSUER_FUND_TOKEN="${entry_token}" \
  ISSUER_FUND_AMOUNT="${entry_amount}" \
  ISSUER_FUND_COUNT="${entry_count}" \
    node --import tsx "${REPO_ROOT}/m1/fund.ts" 2>&1 | tee "${FUND_LOG}" || FUND_RC=$?
  if [ "${FUND_RC}" -ne 0 ]; then
    rm -f "${FUND_LOG}"
    log "ERROR: could not mint ${entry_count} x ${entry_amount} ${entry_token} for ${PROVISION_ROLE}."
    log "ERROR: the service that owns this wallet would start with no inventory. The cause is"
    log "ERROR: in the log above; the manual form is"
    log "ERROR:   docker compose run --rm issuer-fund ${entry_token} ${entry_amount} <seed> ${entry_count}"
    exit "${FUND_RC}"
  fi
  RECEIPT="$(grep -m1 '^ISSUER_FUND_RESULT ' "${FUND_LOG}" || true)"
  rm -f "${FUND_LOG}"
  [ -n "${RECEIPT}" ] || die "the mint of ${entry_token} printed no ISSUER_FUND_RESULT line"
  RECEIPTS="${RECEIPTS}${RECEIPT}
"
done
SECONDS_TAKEN=$(( $(date +%s) - STARTED ))

if [ -n "${MARKER}" ]; then
  mkdir -p "$(dirname "${MARKER}")"
  {
    printf '%s provisioned %s in %ss\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${PROVISION_ROLE}" "${SECONDS_TAKEN}"
    printf 'identity %s\n' "${MARKER_IDENTITY}"
    printf '%s' "${RECEIPTS}"
  } > "${MARKER}"
  log "marker written to ${MARKER}"
fi

printf 'ISSUER_PROVISION_RESULT role=%s recipient=…%s entries=%s revision=%s seconds=%s\n' \
  "${PROVISION_ROLE}" "${RECIPIENT_TAIL}" \
  "$(printf '%s\n' ${SPEC_NORMALISED} | grep -c . || true)" \
  "${REGISTRY_REVISION:-unknown}" "${SECONDS_TAKEN}"
log "${PROVISION_ROLE} inventory complete in ${SECONDS_TAKEN}s"
exit 0
