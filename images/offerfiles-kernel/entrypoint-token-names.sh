#!/usr/bin/env bash
# offerfiles-token-names — register friendly names for the dev tokens the deploy one-shot
# minted. One-shot, `restart: "no"`, runs after the kernel is healthy.
#
# WHY THIS SERVICE EXISTS: the mint cannot name its own colours from where this stack runs it.
# `packages/contracts-midnight/mint-test-tokens.ts` mints three colours and then tries to name
# them over HTTP. It is served BY the kernel — and the kernel waits on the deploy one-shot the
# mint rides (`kernel` -> `offerfiles-deploy: service_completed_successfully`), so at the moment
# the mint runs there is no kernel to POST to. Its registration is a best-effort call wrapped in
# a try/catch that only logs, so the failure is silent and the tokens would exist on chain with
# no names anywhere. Hence a separate one-shot on the other side of that ordering.
#
# HISTORY, because the shape of the upstream failure changed under us:
#   * up to `KERNEL_REF=c293ebd…` the mint POSTed `http://127.0.0.1:9999/api/known-tokens`, the
#     PRE-`/v1` path, which `main` has never served — so the attempt 404'd even when a kernel
#     WAS reachable, and this one-shot was the only thing naming anything.
#   * since `KERNEL_REF=a608fa6…` (kernel PR #68) it POSTs the correct `POST /v1/known-tokens`
#     with `TestTokenA/B/U` at `decimals: 6` and resolves `ZSWAP_API`, falling back to
#     `http://127.0.0.1:9999`. In this stack that is the deploy container's own loopback with
#     nothing listening, so the three POSTs are refused and logged — see the 409 block below for
#     what happens if that ever stops being true.
# Either way the outcome here is the same: this one-shot is what gives the colours their names.
#
# This is a first-party addition, not a patched dependency: it calls the kernel's own public,
# documented endpoint with the colours the deploy one-shot already published. Nothing in
# node_modules is touched.
#
# IDEMPOTENT, BUT NOT CREDULOUS (00018): the endpoint answers 409 when the colour OR the name is
# already registered, which is the normal outcome of a second bring-up — and a 409 is therefore
# treated as SUCCESS ONLY when the registry really does hold THIS stack's colour under THIS
# name. It is read back from `GET /v1/known-tokens` and compared, exactly as
# `images/shielded-night/entrypoint-token-name.sh` has done for SNIGHT since 00011 PR A.
#
# WHY THAT MATTERS SINCE `KERNEL_REF=a608fa6…` (kernel PR #68). Upstream repaired
# `mint-test-tokens.ts`: it now POSTs the correct `/v1/known-tokens` path with the names
# `TestTokenA/B/U` (the kernel uppercases them to `TESTTOKENA/B/U`) at `decimals: 6`, resolving
# `ZSWAP_API` with a `http://127.0.0.1:9999` fallback. In THIS stack that attempt can never
# reach a kernel — the mint rides `offerfiles-deploy`, which runs BEFORE the kernel exists, and
# that service is given no `ZSWAP_API`, so the three POSTs hit the deploy container's own
# loopback, are refused, and are logged as warnings (upstream's helper catches every transport
# failure and only calls `log.warn`). The names this stack ends up with are still the ones
# below. But if that ordering ever changed — a `ZSWAP_API` added to the deploy service, a mint
# retried while the kernel happened to be up — the registry would hold OUR colours under
# `TESTTOKEN*`, this one-shot would 409 on the colour, and taking that 409 at face value would
# leave the whole stack mislabelled in silence: `INTENTS_UI_TOKEN_NAMES`, the SPA's token
# picker, `verify-solver.sh` and the sponsorship gate's name-keyed price map all expect the
# names below. So a 409 whose read-back does not match is FATAL and prints both names.

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
# Set when a 409 turned out to be a real conflict, so the registry is dumped ONCE at the end
# with all three verdicts already printed, rather than three times mid-run.
DUMP_REGISTRY=0

# ── the read-back helpers (00018) ────────────────────────────────────────────
#
# registry_json — the whole registry as the kernel serves it, or the empty string. Never fatal
# on its own: an unreachable kernel here is reported by the caller's own verdict, and this
# one-shot has already waited for /v1/health above.
registry_json() {
  # shellcheck disable=SC2016
  KT_URL="${KERNEL_API_URL}/v1/known-tokens" bun -e '
    const res = await fetch(process.env.KT_URL, { signal: AbortSignal.timeout(15000) })
      .catch(() => ({ text: async () => "" }));
    process.stdout.write(await res.text());
  ' 2>/dev/null || printf ''
}

# registry_dump — the whole registry, one record per line, indented, on stderr. What an
# operator needs in front of them whenever this one-shot refuses to do something.
registry_dump() {
  log "the kernel's token registry, one record per line:"
  printf '%s' "${1}" | tr '{' '\n' | grep '"token_color"' | sed 's/^/      {/' >&2 || true
}

# kernel_name — mirror the kernel's OWN normalisation of a submitted name, so the comparison
# below is against the string the registry actually stores rather than the one we sent:
# `String(body.name).trim().toUpperCase().slice(0, 16)` (packages/node/api.ts). bash 3.2 has no
# `${var^^}`, hence `tr`.
kernel_name() {
  printf '%s' "${1}" \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | tr '[:lower:]' '[:upper:]' \
    | cut -c1-16
}

# record_for — the ONE registry record matching a `"key":"value"` pair, or the empty string.
# `tr '{' '\n'` puts each record on its own line, so a colour and a name that match both belong
# to the SAME record. Every extraction ends in `|| true`: an EMPTY registry (a kernel answering
# 200 with `[]`) must reach the caller as "no such record", not kill the script under
# `set -o pipefail`.
record_for() {
  printf '%s' "${2}" | tr '{' '\n' | grep -F -- "${1}" | head -1 || true
}

field_of() {
  printf '%s' "${2}" | sed -n "s/.*\"${1}\":\"\\([^\"]*\\)\".*/\\1/p" | head -1 || true
}

# Base units per coin for every colour this stack mints. STATED on every registration, never
# left to the column default — see the block comment above `register()`'s POST body.
#
# The literal mirrors `DEFAULT_TOKEN_DECIMALS` in the kernel's own
# `packages/solver-core/amount.ts` (6 since kernel PR #63) and `known_tokens.decimals DEFAULT 6`
# in `packages/database/migrations/000-init.sql`. It is a literal here for the same reason it is
# one in upstream's `entrypoint-register-minted-tokens.sh`: this runs as a bare `bun -e` snippet
# inside the image, with no module to import it from.
MINTED_TOKEN_DECIMALS="${MINTED_TOKEN_DECIMALS:-6}"

register() {
  local json_key="$1" name="$2" kind="$3" colour result
  # Declared here so a verdict from one colour can never leak into the next one's read-back.
  local REG="" WANT_NAME="" COLOUR_ROW="" COLOUR_ROW_NAME="" NAME_ROW="" NAME_ROW_COLOUR=""
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
  #
  # `decimals` IS STATED, not left to the column default (kernel PR #63 / spec FR-003).
  # The faucet mints WHOLE COINS scaled by 10^6 — `mint-test-tokens.ts`'s MINT_AMOUNT is
  # `coinsToBaseUnits(1000n, 6)` = 1_000_000_000 base units, i.e. 1 000 coins — so the registry
  # has to say 6 or every USD price and every sponsorship verdict for this colour is off by
  # 10^6. Explicit beats implicit even though the column now defaults to 6: a kernel pinned
  # BEFORE #63 defaults it to 0, and this one-shot would then silently register three colours
  # at the wrong scale rather than failing. This mirrors upstream's own
  # `deploy/images/kernel/entrypoint-register-minted-tokens.sh`, which states it for the same
  # reason and in the same words.
  # shellcheck disable=SC2016
  result="$(KT_URL="${KERNEL_API_URL}/v1/known-tokens" KT_COLOR="${colour}" \
            KT_NAME="${name}" KT_KIND="${kind}" KT_DECIMALS="${MINTED_TOKEN_DECIMALS}" bun -e '
    const res = await fetch(process.env.KT_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        color: process.env.KT_COLOR,
        name: process.env.KT_NAME,
        kind: process.env.KT_KIND,
        decimals: Number(process.env.KT_DECIMALS),
      }),
      signal: AbortSignal.timeout(15000),
    }).catch((e) => ({ status: 0, text: async () => String(e) }));
    const body = (await res.text()).slice(0, 300);
    process.stdout.write(`${res.status} ${body}`);
  ')" || result="0 (probe failed)"

  case "${result}" in
    2*) log "named ${name} (${kind}) = ${colour} at ${MINTED_TOKEN_DECIMALS} decimals"; REGISTERED=$(( REGISTERED + 1 )) ;;
    # ── 409 IS THE NORMAL SECOND-RUN ANSWER, AND IT IS STILL READ BACK (00018) ─
    #
    # The kernel checks the NAME first and the COLOUR second, and its two 409 bodies say which
    # (`Token name "X" is already taken` / `Token color already registered as "Y"`). That body is
    # logged for the operator, but the VERDICT comes from `GET /v1/known-tokens`, which is
    # authoritative and also tells us what the row actually holds:
    #
    #   our colour, our name  -> SUCCESS. Genuine idempotence: this one-shot re-runs on every
    #                            `up.sh` and must not fail the stack the second time.
    #   our colour, OTHER name -> FATAL. Exactly what a `TESTTOKEN*` row from the repaired
    #                            upstream mint would look like (kernel PR #68). Naming both
    #                            names is the whole point of the message.
    #   our name, OTHER colour -> FATAL. Something else holds the name this stack needs; the
    #                            colour is derived from the contract address, so the foreign row
    #                            is the wrong one — but nothing here deletes a registry row.
    #   neither                -> FATAL. A 409 with no matching record means the registry moved
    #                            under us between the POST and the read-back, or it is
    #                            unreachable. Either way it is not "nothing to do".
    409*)
      REG="$(registry_json)"
      WANT_NAME="$(kernel_name "${name}")"
      COLOUR_ROW="$(record_for "\"token_color\":\"${colour}\"" "${REG}")"
      COLOUR_ROW_NAME="$(field_of name "${COLOUR_ROW}")"
      NAME_ROW="$(record_for "\"name\":\"${WANT_NAME}\"" "${REG}")"
      NAME_ROW_COLOUR="$(field_of token_color "${NAME_ROW}")"
      if [ -n "${COLOUR_ROW}" ] && [ "$(kernel_name "${COLOUR_ROW_NAME}")" = "${WANT_NAME}" ]; then
        log "${name} (${kind}) is already registered as ${colour} — nothing to do"
        log "  registry row: {${COLOUR_ROW}"
        SKIPPED=$(( SKIPPED + 1 ))
      elif [ -n "${COLOUR_ROW}" ]; then
        log "REFUSING to accept this 409: this stack's ${json_key} colour is registered under"
        log "  a DIFFERENT name. expected ${WANT_NAME}, registry says ${COLOUR_ROW_NAME:-<unreadable>}."
        log "  colour ${colour}"
        log "  row    {${COLOUR_ROW}"
        log "  server said: ${result}"
        log "A TESTTOKEN* name here means the kernel's own mint reached a LIVE kernel: since"
        log "KERNEL_REF=a608fa6… (kernel PR #68) mint-test-tokens.ts registers TESTTOKENA/B/U"
        log "itself, and in this stack it must NOT be able to — the mint rides offerfiles-deploy,"
        log "which runs before the kernel exists and is given no ZSWAP_API. Check that nothing"
        log "added one, then ./down.sh -v (the colours are derived from the contract address, so"
        log "a fresh stack gets fresh colours), or rename the rows by hand. Nothing here deletes"
        log "a registry row."
        DUMP_REGISTRY=1
        FAILED=$(( FAILED + 1 ))
      elif [ -n "${NAME_ROW}" ]; then
        log "REFUSING to accept this 409: the name ${WANT_NAME} is held by a colour this stack"
        log "  did not derive."
        log "  our colour   ${colour}"
        log "  their colour ${NAME_ROW_COLOUR:-<unreadable>}"
        log "  their row    {${NAME_ROW}"
        log "  server said: ${result}"
        log "known_tokens.name is UNIQUE. Decide by hand which colour should carry ${WANT_NAME},"
        log "or override this stack's names with TOKEN_NAME_SHIELDED_A/B / TOKEN_NAME_UNSHIELDED."
        DUMP_REGISTRY=1
        FAILED=$(( FAILED + 1 ))
      else
        log "REFUSING to accept this 409: the registry holds NEITHER the colour ${colour} nor the"
        log "  name ${WANT_NAME}, so there is nothing this 409 could be reporting as idempotent."
        log "  server said: ${result}"
        log "  read-back returned ${#REG} byte(s)"
        DUMP_REGISTRY=1
        FAILED=$(( FAILED + 1 ))
      fi
      ;;
    *) log "FAILED to name ${name} (${kind}) ${colour}: ${result}"; FAILED=$(( FAILED + 1 )) ;;
  esac
}

register shieldedA  "${NAME_SHIELDED_A}" shielded
register shieldedB  "${NAME_SHIELDED_B}" shielded
register unshielded "${NAME_UNSHIELDED}" unshielded

log "token names: ${REGISTERED} registered at ${MINTED_TOKEN_DECIMALS} decimals, ${SKIPPED} already present or absent, ${FAILED} failed"

# All three verdicts are printed by now, so the registry is dumped ONCE, with the operator
# already knowing which colour(s) it is about.
if [ "${DUMP_REGISTRY}" -ne 0 ]; then
  registry_dump "$(registry_json)"
fi

# Loud, and fatal: this one-shot exists BECAUSE the upstream failure is silent. A registration
# that fails for a real reason (the registry disabled, a malformed colour, a 409 whose read-back
# shows one of our colours under somebody else's name) must stop the bring-up rather than repeat
# the swallow it was written to fix.
[ "${FAILED}" -eq 0 ] || exit 1
exit 0
