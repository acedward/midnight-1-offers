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

# ── priced, as NIGHT is (phase G), at NIGHT's REAL decimals (phase H2, Q14) ──
#
# Kernel `main` (PR #54) accepts an optional `decimals`/`asset_id` on POST /v1/known-tokens and
# answers 400 with the known ids on an unrecognised one. sNight is registered as `midnight-3` —
# the SAME reference asset as native NIGHT, which is exactly right: one sNight is one wrapped
# NIGHT, 1:1, so pricing it as a second unit of the same asset is not an approximation, it is
# the actual relationship. Fixed, not overridable — a colour claiming a DIFFERENT asset would
# misprice every sNight offer's sponsorship check.
#
# DECIMALS IS THE LITERAL CONSTANT 6, NOT MIRRORED OFF NIGHT'S OWN ROW ANY MORE. Phase G read
# it live because the kernel's seed was WRONG (registered NIGHT at kernel-pricing decimals 0,
# see the plan's phase G log and question Q14) — mirroring a wrong number faithfully reproduced
# it for sNight too. Kernel PR #60 (this project's own upstream fix, phase H1) corrected the
# seed: 1 NIGHT = 10^6 Stars (`STARS_PER_NIGHT` in midnight-ledger/ledger/src/structure.rs;
# `NIGHT-shielded-vs-unshielded-FINDINGS.md`), so NIGHT's kernel-pricing decimals is now
# genuinely 6 — the SAME number as the kernel-pricing convention's definition ("base units per
# PRICED coin") and, not coincidentally, the same number this contract's own on-chain
# `decimals()` circuit answers (a DIFFERENT convention — display decimals — that happens to
# share the value once the kernel's own seed is correct). Hard-coding 6 here is therefore
# CORRECT BY CONSTRUCTION against the fixed seed, not a guess: the wrap circuit locks and mints
# raw units one-for-one (measured: wrapping 1,000,000 raw NIGHT mints exactly 1,000,000 raw
# sNight — phase D′'s live run), so pricing both at the SAME kernel-pricing decimals is what
# makes `GET /v1/quote` genuinely 1:1.
#
# THE ASSERTION BELOW IS WHAT KEEPS THIS HONEST: before posting the literal 6, this one-shot
# reads NIGHT's own row off `GET /v1/prices` and demands it ALSO read exactly 6. A kernel whose
# seed regresses (or is re-pinned to a ref before PR #60) fails LOUDLY here, naming the kernel
# pin as the thing to check, rather than silently registering sNight at a decimals value that
# no longer matches NIGHT's and quietly making `GET /v1/quote` wrong by a power of ten again —
# exactly the failure mode a literal constant would otherwise reintroduce without this check.
ASSET_ID="midnight-3"
NIGHT_COLOR="0000000000000000000000000000000000000000000000000000000000000000"
SNIGHT_DECIMALS=6
# `bun -e fetch`, NOT curl: measured 2026-09-03 — this runtime image (the `deploy` target, FROM
# `oven/bun`) has no `curl` binary at all. curl is installed only in the Dockerfile's separate
# `compact` build stage, never copied into the runtime image. A `curl -fsS ... || true` call
# here therefore fails EVERY time ("command not found", swallowed by `2>/dev/null`) and reads
# exactly like an empty server response — the rest of this file already knew this and used
# `bun -e fetch` throughout; this probe is now consistent with it.
# shellcheck disable=SC2016
PRICES_PROBE="$(KP_URL="${KERNEL_API_URL}/v1/prices?tokens=${NIGHT_COLOR}" bun -e '
  const res = await fetch(process.env.KP_URL, { signal: AbortSignal.timeout(10000) })
    .catch((e) => ({ ok: false, status: 0, text: async () => String(e) }));
  process.stdout.write(await res.text());
')" || PRICES_PROBE=""
case "${PRICES_PROBE}" in
  *"\"asset_id\":\"${ASSET_ID}\""*) log "confirmed ${ASSET_ID} is a seeded asset (GET /v1/prices)" ;;
  *) die "GET /v1/prices does not list ${ASSET_ID} as a seeded asset — cannot register sNight priced against it: ${PRICES_PROBE:0:300}" ;;
esac
NIGHT_DECIMALS="$(printf '%s' "${PRICES_PROBE}" | sed -n 's/.*"token_color":"'"${NIGHT_COLOR}"'"[^}]*"decimals":\([0-9]\+\).*/\1/p' | head -1)"
[ -n "${NIGHT_DECIMALS}" ] || die "could not read NIGHT's own decimals off GET /v1/prices — cannot verify sNight's fixed decimals=${SNIGHT_DECIMALS} against it: ${PRICES_PROBE:0:300}"
if [ "${NIGHT_DECIMALS}" -ne "${SNIGHT_DECIMALS}" ]; then
  die "NIGHT is registered at ${NIGHT_DECIMALS} kernel-pricing decimals, not the expected ${SNIGHT_DECIMALS} — the KERNEL_REF pin (kernel PR #60, NIGHT/USDC decimals 0 -> 6) has moved backward or the seed regressed. Registering sNight at a hard-coded ${SNIGHT_DECIMALS} would make GET /v1/quote wrong by 10^$(( SNIGHT_DECIMALS - NIGHT_DECIMALS )) instead of ~1:1 -- fix the kernel pin, do not mirror this value."
fi
log "NIGHT confirmed at ${NIGHT_DECIMALS} decimals — pricing sNight at the same fixed ${SNIGHT_DECIMALS}"
DECIMALS="${SNIGHT_DECIMALS}"

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
# `decimals`/`asset_id` are what makes sNight a PRICED asset (phase G): without them the row
# registers exactly as before (name only), the kernel's sponsorship gate treats it as
# `unpriced`, and `BATCHER_SPONSOR_UNPRICED` decides its fate rather than a real 1:1-with-NIGHT
# comparison. `${DECIMALS}` is the fixed `${SNIGHT_DECIMALS}` (6) asserted equal to NIGHT's own
# kernel-pricing row above, NOT a value read live off it any more (phase H2, now that kernel PR
# #60 makes 6 the correct, permanent answer) — and it happens to coincide with this dApp's own
# `SHIELDED_NIGHT_DECIMALS` (.env.example, 6), which is a DIFFERENT convention (the contract's
# on-chain display decimals) that is not read here either. See the comment above the probe for
# the full derivation and why a mismatch is fatal rather than mirrored.
#
# `${res.status}` below is a JS template literal evaluated by bun, not a shell expansion.
# shellcheck disable=SC2016
RESULT="$(KT_URL="${KERNEL_API_URL}/v1/known-tokens" KT_COLOR="${COLOR}" KT_NAME="${TOKEN_NAME}" \
          KT_DECIMALS="${DECIMALS}" KT_ASSET_ID="${ASSET_ID}" bun -e '
  const res = await fetch(process.env.KT_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      color: process.env.KT_COLOR,
      name: process.env.KT_NAME,
      kind: "shielded",
      decimals: Number(process.env.KT_DECIMALS),
      asset_id: process.env.KT_ASSET_ID,
    }),
    signal: AbortSignal.timeout(15000),
  }).catch((e) => ({ status: 0, text: async () => String(e) }));
  const body = (await res.text()).slice(0, 300);
  process.stdout.write(`${res.status} ${body}`);
')" || RESULT="0 (probe failed)"

case "${RESULT}" in
  2*)   log "named ${TOKEN_NAME} (shielded) = ${COLOR}, priced as ${ASSET_ID} at ${DECIMALS} decimals" ;;
  409*) log "${TOKEN_NAME} is already registered — nothing to do" ;;
  # Loud and fatal, exactly as offerfiles-token-names is: a 404 NOT_ENABLED means
  # ENABLE_TOKEN_REGISTRY did not reach the kernel as the literal string "true" (it parses THAT
  # variable strictly), a 400 names an unknown asset_id (should not happen — see the preflight
  # above), and a stack whose book cannot name sNight is a stack whose sNight offer shows up as
  # 64 hex characters.
  *)    die "could not name ${TOKEN_NAME} ${COLOR}: ${RESULT}" ;;
esac

exit 0
