#!/usr/bin/env bash
# shielded-night-token-name — make the kernel's token registry say that THIS stack's sNight
# colour is sNight. ONE-SHOT, and one of exactly two things in this profile that know the
# kernel exists.
#
#   docker compose run --rm shielded-night-token-name
#
# ── IT PATCHES BEFORE IT POSTS (00015, organizer issues/00012) ───────────────
# Kernel `main` @ c293ebd SEEDS a SNIGHT row at the PREVIEW contract's colour, and
# `known_tokens.name` is UNIQUE while POST /v1/known-tokens checks the NAME BEFORE the colour
# — so on this stack, where the wrapper contract is deployed per bring-up and the colour is
# different every time, the POST alone can never register the real colour under its own name.
# This one-shot therefore runs the kernel's own prescribed statement first
# (sql/snight-registry-patch.sql: `UPDATE known_tokens … WHERE name = 'SNIGHT'`) and only then
# POSTs, which on a seeded kernel answers the SAME-COLOUR 409 — genuine idempotence.
#
# BEFORE 00015 the same problem was answered by exit 75 here and a
# `DELETE FROM known_tokens WHERE upper(name)='SNIGHT'` in up.sh. Both are gone: this destroys
# no row, needs nothing from the bring-up script, and the SQL is versioned in the image.
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
# The versioned patch this one-shot runs, shipped in the image next to this file. Read it: it
# carries the kernel's own instruction, quoted, and why the POST cannot do this job.
SNIGHT_PATCH_SQL="${SNIGHT_PATCH_SQL:-/usr/local/lib/shielded-night/sql/snight-registry-patch.sql}"
# How long to let the kernel finish syncing, and how long to wait for the chain to leave block
# 1. Both are bounded and both name themselves on timeout — see the block that uses them for
# why "the kernel's healthcheck went green" is not the same question as either of these.
KERNEL_SYNC_TIMEOUT_S="${KERNEL_SYNC_TIMEOUT_S:-300}"
NODE_BLOCK_TIMEOUT_S="${NODE_BLOCK_TIMEOUT_S:-600}"
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

# ── required only from HERE ──────────────────────────────────────────────────
#
# Deliberately after the kernel-presence gate, not at the top of the file. Without a kernel
# this container's whole job is one log line and exit 0 (`--with shielded-night` alone is a
# supported stack), and there is nothing to connect to a database ABOUT. Demanding database
# credentials to reach that conclusion would turn a correct, complete bring-up into an EX_CONFIG
# failure. With a kernel present, every one of these is needed and a missing one must be named
# rather than defaulted: PG* are read by `psql` itself (which is why they carry those names and
# no others), MN_NODE_URL is the chain the height wait asks.
require_env PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE MN_NODE_URL

wait_http "${KERNEL_API_URL}/v1/health" "kernel" "${KERNEL_WAIT_TIMEOUT_S}" \
  || die "the kernel /v1 API never answered at ${KERNEL_API_URL}"

# ── THREE READINESS GATES, AND WHY THE PATCH NEEDS ALL THREE ────────────────
#
# The row this one-shot patches is written by packages/database/migrations/000-init.sql, which
# the KERNEL applies while it brings its database up. A patch that won that race would simply
# be overwritten by the seed and the failure would show up much later as a book that labels
# nothing. So:
#
#   1. `/v1/health` answers               — the socket is there (above).
#   2. `/v1/health/sync` reports `ok`     — the kernel considers itself synced. Note this is
#      the SAME condition compose/offerfiles.yml's healthcheck already gates on (`j.synced ===
#      true`, and the kernel derives `synced` from exactly this status), so on the `up.sh` path
#      it is already true when this container starts and costs one request. It is asserted here
#      anyway because `docker compose run --rm shielded-night-token-name` by hand has no such
#      guarantee.
#   3. the midnight-node is past block 1  — the chain the kernel indexes has actually produced
#      something. `service_healthy` on a Substrate node means "answers RPC", which happens long
#      before genesis+1.
KERNEL_SYNC_STATUS=""
waited=0
log "waiting for the kernel to report itself synced at ${KERNEL_API_URL}/v1/health/sync (timeout ${KERNEL_SYNC_TIMEOUT_S}s)"
while : ; do
  # shellcheck disable=SC2016
  KERNEL_SYNC_STATUS="$(KS_URL="${KERNEL_API_URL}/v1/health/sync" bun -e '
    const res = await fetch(process.env.KS_URL, { signal: AbortSignal.timeout(10000) }).catch(() => null);
    if (!res || !res.ok) process.exit(1);
    const json = await res.json().catch(() => null);
    process.stdout.write(String((json && json.status) || ""));
  ')" || KERNEL_SYNC_STATUS=""
  if [ "${KERNEL_SYNC_STATUS}" = "ok" ]; then
    break
  fi
  waited=$(( waited + 2 ))
  if [ "${waited}" -ge "${KERNEL_SYNC_TIMEOUT_S}" ]; then
    die "TIMEOUT after ${KERNEL_SYNC_TIMEOUT_S}s: ${KERNEL_API_URL}/v1/health/sync never reported status=ok (last answer: ${KERNEL_SYNC_STATUS:-<none>}). Patching the registry now would race the kernel's own seed."
  fi
  sleep 2
done
log "kernel reports /v1/health/sync status=ok"

# Block 2, i.e. height > 1. `wait_node_block` asks chain_getBlockHash for that exact height.
wait_node_block "${MN_NODE_URL}" 2 "${NODE_BLOCK_TIMEOUT_S}" \
  || die "the midnight-node at ${MN_NODE_URL} never reached block 2 — the seed may not have been applied yet"
# The measured height, for the record. Reported, never gated on: the gate above is the exact
# question ("is the chain past block 1"), and a second, racier reading of the tip must not be
# able to fail a bring-up that has already answered it.
# shellcheck disable=SC2016
NODE_HEIGHT="$(MN_NODE_URL="${MN_NODE_URL}" bun -e '
  const res = await fetch(process.env.MN_NODE_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "chain_getHeader", params: [] }),
    signal: AbortSignal.timeout(5000),
  }).catch(() => null);
  if (!res) process.exit(1);
  const json = await res.json().catch(() => null);
  const number = json && json.result && json.result.number;
  if (typeof number !== "string") process.exit(1);
  process.stdout.write(String(Number.parseInt(number, 16)));
')" || NODE_HEIGHT=""
log "midnight-node is at height ${NODE_HEIGHT:-<unreadable>} (> 1 — the kernel's seed has been applied)"

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

# registry_json — GET /v1/known-tokens, or an empty string. Never fatal on its own: every
# caller decides what an unreadable registry means for IT.
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

# ── PATCH THE SEEDED ROW BEFORE POSTING (00015 / issues/00012) ──────────────
#
# See sql/snight-registry-patch.sql for the kernel's own instruction, quoted in full, and for
# why POST /v1/known-tokens cannot do this on its own (the name is UNIQUE and is checked first).
REGISTRY_BEFORE="$(registry_json)"

# THE ONE CASE THAT MUST NOT BE PATCHED THROUGH. `known_tokens.token_color` is UNIQUE, so if
# this stack's real colour is already registered under a DIFFERENT name, the UPDATE would fail
# on the constraint. Refuse first, with the registry in front of the operator, rather than let
# psql answer it as a duplicate-key error — and never by deleting anything: unlike the seeded
# SNIGHT row, a row holding THIS colour is one this stack really did register.
#
# `tr '{' '\n'` puts each record on its own line, so the colour and the name must belong to the
# SAME record. Every extraction ends in `|| true`: an EMPTY registry (a kernel that answers 200
# with `[]`) must reach the checks below as "no clash", not kill the script under `pipefail`.
CLASH_ROW="$(printf '%s' "${REGISTRY_BEFORE}" | tr '{' '\n' \
  | grep -i "\"token_color\":\"${COLOR}\"" | grep -vi '"name":"snight"' | head -1 || true)"
if [ -n "${CLASH_ROW}" ]; then
  log "REFUSING to patch the registry: this stack's sNight colour is ALREADY registered under another name."
  log "  colour ${COLOR}"
  log "  row    {${CLASH_ROW}"
  log "Patching SNIGHT to this colour would violate known_tokens' UNIQUE(token_color). Nothing"
  log "here will delete that row — unlike the kernel's seeded SNIGHT row, a row holding THIS"
  log "colour is one this stack registered. Decide by hand which name the colour should carry."
  registry_dump "${REGISTRY_BEFORE}"
  die "sNight colour ${COLOR} is registered under another name"
fi

# `-t -A` (tuples only, unaligned) so the row line is one greppable line, and NO `-q`: quiet
# mode suppresses psql's command status, and `UPDATE 1` / `UPDATE 0` is exactly the thing this
# step exists to report (measured against psql 17.11 — with -q the tag never appears).
# PGPASSWORD is read by psql out of the environment and is never named on the command line,
# never logged, and never in this file's output.
log "patching the kernel's seeded SNIGHT row: psql -f ${SNIGHT_PATCH_SQL} (host ${PGHOST}:${PGPORT}, db ${PGDATABASE}, user ${PGUSER})"
PATCH_RC=0
PATCH_OUT="$(psql -v ON_ERROR_STOP=1 -t -A \
  -v color="${COLOR}" -v name="${TOKEN_NAME}" -v asset_id="${ASSET_ID}" -v decimals="${DECIMALS}" \
  -f "${SNIGHT_PATCH_SQL}" 2>&1)" || PATCH_RC=$?
printf '%s\n' "${PATCH_OUT}" | sed 's/^/      /' >&2 || true
if [ "${PATCH_RC}" -ne 0 ]; then
  registry_dump "${REGISTRY_BEFORE}"
  die "the registry patch failed (psql exit ${PATCH_RC}) — see the psql output above"
fi
PATCH_ROWS="$(printf '%s' "${PATCH_OUT}" | sed -n 's/^UPDATE \([0-9][0-9]*\).*$/\1/p' | head -1 || true)"
case "${PATCH_ROWS}" in
  1) log "registry patch: UPDATE 1 — the seeded SNIGHT row now carries this stack's colour" ;;
  0) log "registry patch: UPDATE 0 — nothing to change (already patched, or this kernel seeds no SNIGHT row)" ;;
  # A statement that touched more than one row would mean `name` stopped being UNIQUE, which
  # is a schema this profile does not understand. Say so rather than continue.
  "") die "could not read a row count out of psql's output — refusing to continue: ${PATCH_OUT:0:300}" ;;
  *)  die "the registry patch touched ${PATCH_ROWS} rows; known_tokens.name is UNIQUE, so at most 1 was expected: ${PATCH_OUT:0:300}" ;;
esac

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
  # ── 409 IS THE NORMAL ANSWER ON A SEEDED KERNEL, AND IT IS STILL READ BACK ─
  #
  # `known_tokens.name` is UNIQUE and the kernel checks the NAME before the colour, so with the
  # seeded SNIGHT row present (kernel `main` @ c293ebd) this POST answers 409 EVERY time —
  # including the very first run, immediately after the patch above has given that row this
  # stack's colour. That is the genuine-idempotence case and it is what "success" looks like
  # here; a 201 happens only on a kernel that seeds no SNIGHT row at all.
  #
  # It is still not taken at face value: read the registry back and compare colours.
  #   same colour  -> success (the patch worked, or a previous run already did it).
  #   other colour -> HARD FAILURE. Before 00015 this exited 75 and up.sh answered by DELETEing
  #                   the row; now the UPDATE has already run and succeeded, so a foreign colour
  #                   under this name means something changed the row between the patch and this
  #                   POST, or the patch matched no row while some other row holds the name.
  #                   Neither is something to paper over — dump the registry and fail.
  409*)
    OWNER="$(registry_json)"
    OWNER_ROW="$(printf '%s' "${OWNER}" | tr '{' '\n' | grep -i '"name":"snight"' | head -1 || true)"
    OWNER_COLOR="$(printf '%s' "${OWNER_ROW}" | sed -n 's/.*"token_color":"\([0-9a-f]\{64\}\)".*/\1/p' | head -1 || true)"
    if [ "${OWNER_COLOR}" = "${COLOR}" ]; then
      log "${TOKEN_NAME} is already registered as ${COLOR} — nothing to do"
    else
      log "the registry holds ${OWNER_COLOR:-<unreadable>} under the name ${TOKEN_NAME}, but this stack's"
      log "sNight colour is ${COLOR} — and the patch above reported ${PATCH_ROWS} row(s) updated."
      log "This is not the seeded-preview-colour case any more (that is what ${SNIGHT_PATCH_SQL}"
      log "fixes, before this POST): something else is holding the name, or the row moved."
      registry_dump "${OWNER}"
      die "${TOKEN_NAME} names a colour this stack did not derive"
    fi
    ;;
  # Loud and fatal, exactly as offerfiles-token-names is: a 404 NOT_ENABLED means
  # ENABLE_TOKEN_REGISTRY did not reach the kernel as the literal string "true" (it parses THAT
  # variable strictly), a 400 names an unknown asset_id (should not happen — see the preflight
  # above), and a stack whose book cannot name sNight is a stack whose sNight offer shows up as
  # 64 hex characters.
  *)    die "could not name ${TOKEN_NAME} ${COLOR}: ${RESULT}" ;;
esac

exit 0
