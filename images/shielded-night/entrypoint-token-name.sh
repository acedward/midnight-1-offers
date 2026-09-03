#!/usr/bin/env bash
# shielded-night-token-name — tell the offer-files kernel what the sNight colour is called.
# ONE-SHOT, and one of exactly two things in this profile that know the kernel exists.
#
#   docker compose run --rm shielded-night-token-name
#
# ── WHY A COLOUR NEEDS A NAME AT ALL ─────────────────────────────────────────
# sNight's colour is derived from the CONTRACT ADDRESS (`tokenType(pad(32,
# "shielded-night:wrapper"), self())`), so it is different on every fresh stack and cannot be
# hard-coded anywhere. Without this registration the zswap-da SPA shows an sNight offer as 64
# hex characters, and nothing in the stack can tell an operator that those characters are the
# NIGHT they wrapped one page over. It is the same gap `offerfiles-token-names` fills for the
# minted DEVA/DEVB/DEVU demo colours, and this mirrors that one-shot deliberately, down to
# treating 409 as success.
#
# ── THIS PROFILE MUST NEVER DEPEND ON `offerfiles` (spec FR-002/FR-015) ──────
# `./up.sh --with shielded-night` alone is legal and complete, so nothing here may require a
# kernel. Two consequences, both load-bearing:
#
#   * the service carries NO `depends_on` naming a kernel — it could not: compose rejects a
#     `depends_on` (even `required: false`) that names a service no selected fragment defines,
#     which is exactly the case when this profile is up alone. MEASURED on compose v5.4.0.
#   * therefore ORDERING comes from the caller: the service declares `deploy: { replicas: 0 }`,
#     so `up.sh` never starts it implicitly, and `up.sh` runs it explicitly — after the kernel
#     is healthy — only when `service_present kernel` says the offerfiles profile is up. Run
#     with no kernel on the network, this exits 0 with ONE line rather than failing a stack
#     that is behaving exactly as documented.

# Consumed by log() in the sourced prelude, which shellcheck cannot see from here.
# shellcheck disable=SC2034
ROLE=shielded-night-token-name
# shellcheck source=images/shielded-night/entrypoint-common.sh
. /usr/local/lib/shielded-night/entrypoint-common.sh

KERNEL_API_URL="${KERNEL_API_URL:-http://kernel:9999}"
TOKEN_NAME="${SHIELDED_NIGHT_TOKEN_NAME:-${SHIELDED_NIGHT_SYMBOL:-sNight}}"
# How long to wait for a kernel that IS on this network to become answerable. Short by
# comparison with the stack's other waits because `up.sh` has already blocked on the kernel's
# healthcheck before invoking this; the budget is for the case an operator runs it by hand.
KERNEL_WAIT_TIMEOUT_S="${KERNEL_WAIT_TIMEOUT_S:-300}"
# How long to spend deciding the kernel is ABSENT rather than merely slow. A name that does
# not resolve is answered by DNS immediately, so this is small on purpose: on a stack without
# the offerfiles profile it is the whole cost of this container.
KERNEL_DISCOVERY_TIMEOUT_S="${KERNEL_DISCOVERY_TIMEOUT_S:-20}"

# The contract must exist before a colour can be derived from it. compose gates this service on
# the deploy one-shot; the wait is for a hand-run against a stack still coming up.
CONTRACT_WAIT_TIMEOUT_S="${CONTRACT_WAIT_TIMEOUT_S:-600}"
waited=0
while [ ! -f "${CONTRACT_FILE}" ]; do
  waited=$(( waited + 2 ))
  if [ "${waited}" -ge "${CONTRACT_WAIT_TIMEOUT_S}" ]; then
    die "TIMEOUT after ${CONTRACT_WAIT_TIMEOUT_S}s: ${CONTRACT_FILE} — the deploy one-shot published nothing"
  fi
  sleep 2
done

# ── is there a kernel on this network at all? ────────────────────────────────
#
# The question is deliberately "does the NAME resolve", not "does the API answer": a kernel
# that is present but still booting must be WAITED for, while an absent one must be reported
# and skipped in seconds. Those are different answers to different questions, and collapsing
# them into one HTTP probe would either fail a legitimate `--with shielded-night` stack or turn
# every solo bring-up into a multi-minute timeout.
KERNEL_HOST="$(printf '%s' "${KERNEL_API_URL}" | sed -e 's#^[a-z][a-z0-9+.-]*://##' -e 's#[/?].*$##' -e 's#:[0-9]*$##')"
[ -n "${KERNEL_HOST}" ] || die "KERNEL_API_URL=${KERNEL_API_URL} has no host part"

resolves=0
waited=0
while : ; do
  if KERNEL_HOST="${KERNEL_HOST}" bun -e '
    const { lookup } = await import("node:dns/promises");
    await lookup(process.env.KERNEL_HOST).then(() => process.exit(0), () => process.exit(1));
  ' >/dev/null 2>&1; then
    resolves=1
    break
  fi
  waited=$(( waited + 2 ))
  [ "${waited}" -ge "${KERNEL_DISCOVERY_TIMEOUT_S}" ] && break
  sleep 2
done

if [ "${resolves}" -ne 1 ]; then
  log "no kernel on this network (${KERNEL_HOST} does not resolve) — nothing to name; the offerfiles profile is not up"
  exit 0
fi

wait_http "${KERNEL_API_URL}/v1/health" "kernel" "${KERNEL_WAIT_TIMEOUT_S}" \
  || die "the kernel /v1 API never answered at ${KERNEL_API_URL}"

# ── the colour, derived exactly as the page derives it ───────────────────────
#
# Through the driver, not a second copy of the derivation: driver/snight-driver.ts computes
# `rawTokenType(pad32("shielded-night:wrapper"), address)` — byte-for-byte the frontend's
# `deriveWrapperColorHex` — and the `wrap` mode cross-checks it against the contract's own
# `tokenColor()` circuit. One implementation, checked against the chain in one place.
cd "${REPO_ROOT}" || die "no ${REPO_ROOT}"
COLOR_OUT="$(bun run driver/snight-driver.ts color)" || die "could not derive the sNight colour"
COLOR="$(printf '%s\n' "${COLOR_OUT}" | sed -n 's/^SNIGHT_RESULT .*color=\([0-9a-f]\{64\}\).*$/\1/p' | head -1)"
[ -n "${COLOR}" ] || die "the driver printed no usable colour: ${COLOR_OUT}"
log "sNight colour ${COLOR}"

# ── register it ──────────────────────────────────────────────────────────────
#
# IDEMPOTENT BY THE SERVER'S OWN SEMANTICS, not by a marker file, which is what
# `offerfiles-token-names` does and for the same reason: this one-shot re-runs on every
# `./up.sh` and a 409 ("colour already registered", "name already taken") is the normal second
# answer. A marker would additionally have to be invalidated when `./down.sh -v` gives the
# stack a new contract and therefore a new colour, and forgetting that is a silent wrong label.
#
# NOTE the kernel UPPERCASES the name (`String(body.name).trim().toUpperCase().slice(0,16)`),
# so `sNight` is stored as `SNIGHT`. verify asserts it case-insensitively.
#
# `${res.status}` below is a JS template literal evaluated by bun, not a shell expansion.
# shellcheck disable=SC2016
RESULT="$(KT_URL="${KERNEL_API_URL}/v1/known-tokens" KT_COLOR="${COLOR}" KT_NAME="${TOKEN_NAME}" bun -e '
  const res = await fetch(process.env.KT_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ color: process.env.KT_COLOR, name: process.env.KT_NAME, kind: "shielded" }),
    signal: AbortSignal.timeout(15000),
  }).catch((e) => ({ status: 0, text: async () => String(e) }));
  const body = (await res.text()).slice(0, 300);
  process.stdout.write(`${res.status} ${body}`);
')" || RESULT="0 (probe failed)"

case "${RESULT}" in
  2*)   log "named ${TOKEN_NAME} (shielded) = ${COLOR}" ;;
  409*) log "${TOKEN_NAME} is already registered — nothing to do" ;;
  # Loud and fatal, exactly as offerfiles-token-names is: a 404 NOT_ENABLED means
  # ENABLE_TOKEN_REGISTRY did not reach the kernel as the literal string "true" (it parses THAT
  # variable strictly), and a stack whose book cannot name sNight is a stack whose sNight offer
  # shows up as 64 hex characters.
  *)    die "could not name ${TOKEN_NAME} ${COLOR}: ${RESULT}" ;;
esac

exit 0
