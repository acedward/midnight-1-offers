#!/usr/bin/env bash
# offerfiles-token-names — register friendly names for the dev tokens the deploy one-shot
# minted. One-shot, `restart: "no"`, runs after the kernel is healthy.
#
# WHY THIS SERVICE EXISTS: an upstream bug leaves the mint half-finished.
# `packages/contracts-midnight/mint-test-tokens.ts` mints three colours and then tries to name
# them by POSTing to `http://127.0.0.1:9999/api/known-tokens` — the PRE-`/v1` path. The server
# on main serves `POST /v1/known-tokens` and nothing at `/api/known-tokens`, and the mint
# script wraps that call in a bare try/catch. So the request 404s, the failure is swallowed,
# and the tokens exist on chain with no names anywhere. Nothing reports it.
#
# The names cannot be registered by the deploy one-shot itself, which is where the mint runs:
# `POST /v1/known-tokens` is served BY the kernel, and the kernel waits on the deploy one-shot
# to finish before it starts. Hence a separate one-shot on the other side of that ordering.
#
# This is a first-party addition, not a patched dependency: it calls the kernel's own public,
# documented endpoint with the colours the deploy one-shot already published. Nothing in
# node_modules is touched.
#
# IDEMPOTENT: the endpoint answers 409 when a colour or a name is already registered, which is
# treated as success — this one-shot re-runs on every `up.sh` and must not fail the stack the
# second time.

# Consumed by log() in the sourced prelude, which shellcheck cannot see from here.
# shellcheck disable=SC2034
ROLE=token-names
# shellcheck source=images/offerfiles-kernel/entrypoint-common.sh
. /usr/local/lib/offerfiles/entrypoint-common.sh

require_env KERNEL_API_URL

PUBLISHED_MINTED="${CONTRACT_SHARE_DIR}/${MINTED_FILE}"

# The mint is deliberately non-fatal in the deploy one-shot, so its output may legitimately be
# absent. Say so and exit 0: a stack without demo token NAMES is fully usable, and failing here
# would turn a cosmetic gap into a broken bring-up.
if [ ! -f "${PUBLISHED_MINTED}" ]; then
  log "no ${PUBLISHED_MINTED} — the mint did not publish any colours, so there is nothing to name"
  log "(the deploy one-shot logs why; the stack works without token names)"
  exit 0
fi

wait_http "${KERNEL_API_URL}/v1/health" "kernel" "${KERNEL_WAIT_TIMEOUT_S:-600}" \
  || die "the kernel /v1 API never answered at ${KERNEL_API_URL}"

# Colours are derived from the DEPLOYED CONTRACT ADDRESS plus a fixed domain separator, so they
# differ on every fresh stack and can only come from the file. The names are ours, and are
# overridable so a demo can relabel them without touching this image.
NAME_SHIELDED_A="${TOKEN_NAME_SHIELDED_A:-DEVA}"
NAME_SHIELDED_B="${TOKEN_NAME_SHIELDED_B:-DEVB}"
NAME_UNSHIELDED="${TOKEN_NAME_UNSHIELDED:-DEVU}"

REGISTERED=0
SKIPPED=0
FAILED=0

register() {
  local json_key="$1" name="$2" kind="$3" colour result
  colour="$(MINTED_JSON_PATH="${PUBLISHED_MINTED}" MINTED_KEY="${json_key}" bun -e '
    const json = await Bun.file(process.env.MINTED_JSON_PATH).json();
    const value = json[process.env.MINTED_KEY];
    process.stdout.write(typeof value === "string" ? value : "");
  ')" || colour=""

  if [ -z "${colour}" ]; then
    log "WARNING: ${json_key} is absent from ${PUBLISHED_MINTED} — not naming it"
    SKIPPED=$(( SKIPPED + 1 ))
    return 0
  fi

  # A 409 means the colour or the name is already registered, which is the normal outcome of a
  # second bring-up. Anything else non-2xx is reported with the server's own reason: a 404
  # NOT_ENABLED, for instance, means ENABLE_TOKEN_REGISTRY did not reach the kernel as the
  # literal string "true" (main parses THAT variable strictly, unlike its other booleans).
  # `${res.status}` below is a JS template literal evaluated by bun, not a shell expansion.
  # shellcheck disable=SC2016
  result="$(KT_URL="${KERNEL_API_URL}/v1/known-tokens" KT_COLOR="${colour}" \
            KT_NAME="${name}" KT_KIND="${kind}" bun -e '
    const res = await fetch(process.env.KT_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        color: process.env.KT_COLOR,
        name: process.env.KT_NAME,
        kind: process.env.KT_KIND,
      }),
      signal: AbortSignal.timeout(15000),
    }).catch((e) => ({ status: 0, text: async () => String(e) }));
    const body = (await res.text()).slice(0, 300);
    process.stdout.write(`${res.status} ${body}`);
  ')" || result="0 (probe failed)"

  case "${result}" in
    2*) log "named ${name} (${kind}) = ${colour}"; REGISTERED=$(( REGISTERED + 1 )) ;;
    409*) log "${name} (${kind}) already registered — nothing to do"; SKIPPED=$(( SKIPPED + 1 )) ;;
    *) log "FAILED to name ${name} (${kind}) ${colour}: ${result}"; FAILED=$(( FAILED + 1 )) ;;
  esac
}

register shieldedA  "${NAME_SHIELDED_A}" shielded
register shieldedB  "${NAME_SHIELDED_B}" shielded
register unshielded "${NAME_UNSHIELDED}" unshielded

log "token names: ${REGISTERED} registered, ${SKIPPED} already present or absent, ${FAILED} failed"

# Loud, and fatal: this one-shot exists BECAUSE the upstream failure is silent. A registration
# that fails for a real reason (the registry disabled, a malformed colour) must stop the
# bring-up rather than repeat the swallow it was written to fix.
[ "${FAILED}" -eq 0 ] || exit 1
exit 0
