#!/usr/bin/env bash
# issuer-registrar — make the offer-files kernel's token registry say that THIS stack's six
# issuer colours are TWBTC, TWETH, TWUSDC, TWUSDM, UTWUSDC and UTWBTC. ONE-SHOT.
#
#   docker compose run --rm --no-deps issuer-registrar
#
# ── IT PATCHES BEFORE IT POSTS, SIX TIMES (the 00015 mechanism, generalised) ─
# Kernel `main` @ e3b9388 (PR #69) SEEDS all six of those names at the colours of the public
# PREPROD deployment, and `known_tokens.name` is UNIQUE while POST /v1/known-tokens checks the
# NAME before the colour — so on this stack, where six issuer contracts are deployed per
# bring-up and every colour is different every time, the POST alone can never register a real
# colour under its own name. Each token therefore gets the kernel's own prescribed statement
# first (sql/issuer-registry-patch.sql: `UPDATE known_tokens … WHERE upper(name) = …`) and only
# then a POST, which on a seeded kernel answers the name-taken 409 — genuine idempotence.
#
# It is CORRECT ON BOTH KERNEL PINS, and this is not incidental:
#
#   kernel a608fa6 (the pin this stack runs today)  seeds NIGHT/SNIGHT/USDC/USDM and NO TW* row.
#       → every UPDATE reports `UPDATE 0`, every POST answers 201 and creates the row.
#   kernel e3b9388 (phase C)                        seeds the six names at Preprod colours.
#       → every UPDATE reports `UPDATE 1`, every POST answers 409 and the read-back proves the
#         row now holds this stack's colour.
#
# Both are success, and the log says which happened, so an operator can tell which kernel they
# are on from this one-shot alone.
#
# ── THIS PROFILE MUST NEVER DEPEND ON `offerfiles` ──────────────────────────
# `./up.sh --with issuer` alone is legal and complete — it deploys the tokens and serves the
# faucet — so nothing in the fragment may require a kernel. Two consequences, both load-bearing
# and both copied from `shielded-night-token-name` (compose/shielded-night.yml), which solved
# exactly this problem for one token:
#
#   * the service carries NO `depends_on` naming a kernel: compose REJECTS a `depends_on` (even
#     `required: false`) that names a service no selected fragment defines, which is precisely
#     the case when `issuer` is up without `offerfiles`. MEASURED on compose v5.4.0:
#     `service "x" depends on undefined service "kernel": invalid compose project`.
#   * therefore ORDERING comes from the caller: the service declares `deploy: { replicas: 0 }`,
#     so `up.sh` never starts it implicitly, and `up.sh` runs it explicitly — after the kernel
#     is healthy — only when `service_present kernel` says the offerfiles profile is up. Run
#     against a network with no kernel, this exits 0 with ONE line rather than failing a stack
#     that is behaving exactly as documented.
#
# ── WHY IT WAITS FOR THE CHAIN ──────────────────────────────────────────────
# The seed is applied by the kernel while its database comes up, so this waits on all three of:
# `/v1/health` answering, `/v1/health/sync` reporting `ok`, and the midnight-node being past
# block 1. A patch that won that race would be overwritten by the seed, and the failure would
# surface much later as an unlabelled book.

# Consumed by log() in the sourced prelude, which shellcheck cannot see from here.
# shellcheck disable=SC2034
ROLE=issuer-registrar
# shellcheck source=images/issuer/entrypoint-common.sh
. /usr/local/lib/issuer/entrypoint-common.sh

KERNEL_API_URL="${KERNEL_API_URL:-http://kernel:9999}"
PATCH_SQL="${ISSUER_PATCH_SQL:-/usr/local/lib/issuer/sql/issuer-registry-patch.sql}"
KERNEL_SYNC_TIMEOUT_S="${KERNEL_SYNC_TIMEOUT_S:-300}"
NODE_BLOCK_TIMEOUT_S="${NODE_BLOCK_TIMEOUT_S:-600}"
KERNEL_WAIT_TIMEOUT_S="${KERNEL_WAIT_TIMEOUT_S:-300}"
# How long to spend deciding the kernel is ABSENT rather than merely slow. A name that does not
# resolve is answered by DNS immediately, so this is small on purpose: on a stack without the
# offerfiles profile it is the whole cost of this container.
KERNEL_DISCOVERY_TIMEOUT_S="${KERNEL_DISCOVERY_TIMEOUT_S:-20}"
REGISTRY_WAIT_TIMEOUT_S="${REGISTRY_WAIT_TIMEOUT_S:-1800}"

# ── THE CoinGecko REFERENCE ASSET PER TOKEN ─────────────────────────────────
#
# The registry file carries no `asset_id`: it is a KERNEL concept ("Reference asset (a
# CoinGecko id). Omitted means 'price it by NAME through price-map.ts'"). These six values are
# exactly the ones the kernel's own `000-init.sql` seeds beside the six names at e3b9388, so a
# stack on that pin ends up with the row the seed intended, at this stack's colour. All five
# ids used here are in the `asset_prices` seed at BOTH kernel pins (measured), so the POST
# cannot 400 on an unknown asset — and the preflight below proves it live rather than trusting
# the measurement.
#
# WHY NOT OMIT IT AND LET price-map.ts PRICE BY NAME: because `GET /v1/prices` reports
# `unpriced` for a colour with no asset, and the batcher's sponsorship gate then decides its
# fate by `BATCHER_SPONSOR_UNPRICED` instead of by a real USD comparison. A twBTC offer that is
# sponsored or refused for the wrong reason is much harder to diagnose than a wrong price.
asset_id_for() {
  case "$1" in
    TWBTC|UTWBTC)  printf 'bitcoin' ;;
    TWETH)         printf 'ethereum' ;;
    TWUSDC|UTWUSDC) printf 'usd-coin' ;;
    TWUSDM)        printf 'usdm-2' ;;
    *) return 1 ;;
  esac
}

# ── is there a kernel on this network at all? ────────────────────────────────
#
# The question is deliberately "does the NAME resolve", not "does the API answer": a kernel
# that is present but still booting must be WAITED for, while an absent one must be reported
# and skipped in seconds. Those are different answers to different questions, and collapsing
# them into one HTTP probe would either fail a legitimate `--with issuer` stack or turn every
# solo bring-up into a multi-minute timeout.
KERNEL_HOST="$(printf '%s' "${KERNEL_API_URL}" | sed -e 's#^[a-z][a-z0-9+.-]*://##' -e 's#[/?].*$##' -e 's#:[0-9]*$##')"
[ -n "${KERNEL_HOST}" ] || die "KERNEL_API_URL=${KERNEL_API_URL} has no host part"

resolves=0
waited=0
while : ; do
  if getent hosts "${KERNEL_HOST}" >/dev/null 2>&1; then
    resolves=1
    break
  fi
  waited=$(( waited + 2 ))
  [ "${waited}" -ge "${KERNEL_DISCOVERY_TIMEOUT_S}" ] && break
  sleep 2
done

if [ "${resolves}" -ne 1 ]; then
  log "no kernel on this network (${KERNEL_HOST} does not resolve) — nothing to register;"
  log "the offerfiles profile is not up. The registry is still published for the faucet site"
  log "and for issuer-fund: ${ISSUER_REGISTRY_FILE}"
  exit 0
fi

# ── required only from HERE ──────────────────────────────────────────────────
#
# Deliberately after the kernel-presence gate, not at the top of the file. Without a kernel this
# container's whole job is one log line and exit 0, and there is nothing to connect to a
# database ABOUT. Demanding database credentials to reach that conclusion would turn a correct,
# complete bring-up into an EX_CONFIG failure. PG* are read by `psql` itself, which is why they
# carry those names and no others; MN_NODE_URL is the chain the height wait asks.
require_env PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE MN_NODE_URL

# ── the registry this one-shot reads ─────────────────────────────────────────
# compose gates this service on nothing (it has `replicas: 0`), so the wait is real: `up.sh`
# runs it after `issuer-deploy` has completed, but an operator may run it at any time.
waited=0
while [ ! -f "${ISSUER_REGISTRY_FILE}" ]; do
  waited=$(( waited + 5 ))
  if [ "${waited}" -ge "${REGISTRY_WAIT_TIMEOUT_S}" ]; then
    die "TIMEOUT after ${REGISTRY_WAIT_TIMEOUT_S}s: ${ISSUER_REGISTRY_FILE} — the issuer-deploy one-shot published nothing"
  fi
  [ "$(( waited % 60 ))" -eq 0 ] && log "waiting for ${ISSUER_REGISTRY_FILE} (${waited}s/${REGISTRY_WAIT_TIMEOUT_S}s)"
  sleep 5
done

cd "${REPO_ROOT}" || die "no ${REPO_ROOT}"

# The six tokens, validated and in canonical order, from the one script that knows how to read
# this file. Its `ISSUER_TOKEN` lines are the interface; this one-shot never parses the JSON
# itself, so there is exactly one registry reader in this image.
REPORT="$(node --import tsx "${REPO_ROOT}/m1/registry.ts")" || die "the registry did not validate — refusing to register anything from it"
TOKEN_LINES="$(printf '%s\n' "${REPORT}" | grep '^ISSUER_TOKEN ' || true)"
TOKEN_COUNT="$(printf '%s\n' "${TOKEN_LINES}" | grep -c '^ISSUER_TOKEN ' || true)"
[ "${TOKEN_COUNT}" = "6" ] || die "the registry describes ${TOKEN_COUNT} active token(s), expected 6"
printf '%s\n' "${REPORT}" | grep '^ISSUER_REGISTRY ' | sed 's/^/      /' >&2 || true

# ── the kernel's readiness, all three gates ─────────────────────────────────
wait_http "${KERNEL_API_URL}/v1/health" "kernel" "${KERNEL_WAIT_TIMEOUT_S}" \
  || die "the kernel /v1 API never answered at ${KERNEL_API_URL}"

KERNEL_SYNC_STATUS=""
waited=0
log "waiting for the kernel to report itself synced at ${KERNEL_API_URL}/v1/health/sync (timeout ${KERNEL_SYNC_TIMEOUT_S}s)"
while : ; do
  KERNEL_SYNC_STATUS="$(curl -sS --max-time 10 "${KERNEL_API_URL}/v1/health/sync" 2>/dev/null \
    | sed -n 's/.*"status":"\([a-z]*\)".*/\1/p' | head -1 || true)"
  [ "${KERNEL_SYNC_STATUS}" = "ok" ] && break
  waited=$(( waited + 2 ))
  if [ "${waited}" -ge "${KERNEL_SYNC_TIMEOUT_S}" ]; then
    die "TIMEOUT after ${KERNEL_SYNC_TIMEOUT_S}s: ${KERNEL_API_URL}/v1/health/sync never reported status=ok (last answer: ${KERNEL_SYNC_STATUS:-<none>}). Patching the registry now would race the kernel's own seed."
  fi
  sleep 2
done
log "kernel reports /v1/health/sync status=ok"

# Block 2, i.e. height > 1.
wait_node_block 2 "${NODE_BLOCK_TIMEOUT_S}" \
  || die "the midnight-node at ${MN_NODE_URL} never reached block 2 — the seed may not have been applied yet"
HEIGHT="$(node_height || true)"
log "midnight-node is at height ${HEIGHT:-<unreadable>} (> 1 — the kernel's seed has been applied)"

# ── helpers ──────────────────────────────────────────────────────────────────

# registry_json — GET /v1/known-tokens, or an empty string. Never fatal on its own: every
# caller decides what an unreadable registry means for IT.
registry_json() {
  curl -sS --max-time 15 "${KERNEL_API_URL}/v1/known-tokens" 2>/dev/null || printf ''
}

# registry_dump — the whole registry, one record per line, indented, on stderr. What an operator
# needs in front of them whenever this one-shot refuses to do something.
registry_dump() {
  log "the kernel's token registry, one record per line:"
  printf '%s' "${1}" | tr '{' '\n' | grep '"token_color"' | sed 's/^/      {/' >&2 || true
}

# row_field <registry-json> <name> <field> — the value of one field of the record carrying that
# NAME. `tr '{' '\n'` puts each record on its own line so the name and the field must belong to
# the SAME record. Every extraction ends in `|| true`: an EMPTY registry (a kernel that answers
# 200 with `[]`) must reach the checks below as "absent", not kill the script under `pipefail`.
row_field() {
  printf '%s' "${1}" | tr '{' '\n' \
    | grep -i "\"name\":\"${2}\"" | head -1 \
    | sed -n "s/.*\"${3}\":\"\{0,1\}\([^,\"}]*\)\"\{0,1\}.*/\1/p" | head -1 || true
}

# ── the ASSET PREFLIGHT, once, before any row is touched ────────────────────
#
# A colour claiming an asset nobody seeded answers 400 from the POST route
# (`Unknown asset_id "x" — known: …`), and the registrar would die on the first one — so the
# value of asking first is not fewer errors, it is asking a question the API cannot answer.
#
# IT IS A DATABASE QUERY, NOT AN API CALL, and that is measured rather than chosen:
# `GET /v1/prices` REQUIRES a `tokens=` parameter (1–50 comma-separated 64-hex colours) and its
# `assets[]` array is SCOPED TO THE ASSETS OF THE TOKENS ASKED FOR — measured on this stack:
# `?tokens=<NIGHT>` answers with `midnight-3` alone, and a bare `GET /v1/prices` answers
# `{"error":"VALIDATION","reason":"tokens is required…"}`. There is no endpoint that lists the
# seeded asset set, and the tokens whose asset ids this one-shot needs are precisely the ones
# not registered yet. `asset_prices` is the table the kernel's own FK points at, this container
# already has psql and the credentials, and asking it PROVES THOSE CREDENTIALS WORK before the
# first UPDATE — which a wrong PGPASSWORD would otherwise turn into a confusing patch failure.
ASSETS_RC=0
ASSETS_OUT="$(psql -v ON_ERROR_STOP=1 -t -A -c 'SELECT asset_id FROM asset_prices ORDER BY asset_id' 2>&1)" || ASSETS_RC=$?
if [ "${ASSETS_RC}" -ne 0 ]; then
  printf '%s\n' "${ASSETS_OUT}" | sed 's/^/      /' >&2 || true
  die "could not read asset_prices from ${PGHOST}:${PGPORT}/${PGDATABASE} as ${PGUSER} (psql exit ${ASSETS_RC})"
fi
log "asset_prices holds: $(printf '%s' "${ASSETS_OUT}" | tr '\n' ' ' || true)"
for a in bitcoin ethereum usd-coin usdm-2; do
  if ! printf '%s\n' "${ASSETS_OUT}" | grep -qx -- "${a}"; then
    die "asset_prices has no \"${a}\" row — this kernel cannot price the issuer tokens, and POST /v1/known-tokens would answer 400. Check KERNEL_REF."
  fi
done
log "confirmed the four reference assets (bitcoin, ethereum, usd-coin, usdm-2) are seeded"

# ── register the six, one at a time ─────────────────────────────────────────
UPDATED=0
CREATED=0
ALREADY=0
FAILED=0
SUMMARY=""

REGISTRY_BEFORE="$(registry_json)"

while IFS= read -r line; do
  [ -n "${line}" ] || continue
  NAME="$(printf '%s' "${line}" | awk '{print $2}')"
  SYMBOL="$(printf '%s' "${line}" | sed -n 's/.* symbol=\([^ ]*\).*/\1/p')"
  PRIVACY="$(printf '%s' "${line}" | sed -n 's/.* privacy=\([^ ]*\).*/\1/p')"
  DECIMALS="$(printf '%s' "${line}" | sed -n 's/.* decimals=\([0-9]*\).*/\1/p')"
  COLOR="$(printf '%s' "${line}" | sed -n 's/.* id=\([0-9a-f]\{64\}\).*/\1/p')"
  ASSET_ID="$(asset_id_for "${NAME}")" || die "no reference asset is defined for ${NAME} — this file and the registry have diverged"

  case "${PRIVACY}" in
    shielded|unshielded) : ;;
    *) die "${NAME}: privacy \"${PRIVACY}\" is neither shielded nor unshielded" ;;
  esac
  case "${DECIMALS}" in
    ''|*[!0-9]*) die "${NAME}: decimals \"${DECIMALS}\" is not a number" ;;
  esac
  [ -n "${COLOR}" ] || die "${NAME}: the registry line carries no 64-hex token id: ${line}"

  log "── ${NAME} (${SYMBOL}) ${PRIVACY} ${DECIMALS} decimals asset ${ASSET_ID}"
  log "   colour ${COLOR}"

  # THE ONE CASE THAT MUST NOT BE PATCHED THROUGH. `known_tokens.token_color` is UNIQUE, so if
  # this stack's colour is already registered under a DIFFERENT name, the UPDATE would fail on
  # the constraint. Refuse first, with the registry in front of the operator, rather than let
  # psql answer it as a duplicate-key error — and never by deleting anything.
  CLASH_ROW="$(printf '%s' "${REGISTRY_BEFORE}" | tr '{' '\n' \
    | grep -i "\"token_color\":\"${COLOR}\"" | grep -vi "\"name\":\"${NAME}\"" | head -1 || true)"
  if [ -n "${CLASH_ROW}" ]; then
    log "REFUSING to patch: this stack's ${NAME} colour is ALREADY registered under another name."
    log "  row {${CLASH_ROW}"
    registry_dump "${REGISTRY_BEFORE}"
    die "${NAME} colour ${COLOR} is registered under another name"
  fi

  # `-t -A` (tuples only, unaligned) so the row line is one greppable line, and NO `-q`: quiet
  # mode suppresses psql's command status, and `UPDATE 1` / `UPDATE 0` is exactly the thing this
  # step exists to report (measured against psql 17 — with -q the tag never appears).
  # PGPASSWORD is read by psql out of the environment and is never named on a command line,
  # never logged, and never in this file's output.
  PATCH_RC=0
  PATCH_OUT="$(psql -v ON_ERROR_STOP=1 -t -A \
    -v name="${NAME}" -v color="${COLOR}" -v kind="${PRIVACY}" \
    -v decimals="${DECIMALS}" -v asset_id="${ASSET_ID}" \
    -f "${PATCH_SQL}" 2>&1)" || PATCH_RC=$?
  printf '%s\n' "${PATCH_OUT}" | sed 's/^/      /' >&2 || true
  if [ "${PATCH_RC}" -ne 0 ]; then
    registry_dump "${REGISTRY_BEFORE}"
    die "${NAME}: the registry patch failed (psql exit ${PATCH_RC}) — see the psql output above"
  fi
  PATCH_ROWS="$(printf '%s' "${PATCH_OUT}" | sed -n 's/^UPDATE \([0-9][0-9]*\).*$/\1/p' | head -1 || true)"
  case "${PATCH_ROWS}" in
    1) log "   patch: UPDATE 1 — the seeded ${NAME} row now carries this stack's colour"; UPDATED=$(( UPDATED + 1 )) ;;
    0) log "   patch: UPDATE 0 — nothing to change (already patched, or this kernel seeds no ${NAME} row)" ;;
    "") die "${NAME}: could not read a row count out of psql's output: ${PATCH_OUT:0:300}" ;;
    *)  die "${NAME}: the patch touched ${PATCH_ROWS} rows; known_tokens.name is UNIQUE, so at most 1 was expected" ;;
  esac

  # ── the POST ───────────────────────────────────────────────────────────────
  # IDEMPOTENT BY THE SERVER'S OWN SEMANTICS, not by a marker file: this one-shot re-runs on
  # every `./up.sh` and a 409 is the normal second answer. A marker would additionally have to
  # be invalidated whenever `./down.sh -v` gives the stack six new contracts and six new
  # colours, and forgetting that is six silently wrong labels.
  #
  # The kernel UPPERCASES the name and truncates it to 16 characters
  # (`String(body.name).trim().toUpperCase().slice(0,16)`); every name here is already
  # upper-case and at most 7 characters, so nothing is transformed.
  POST_BODY="$(printf '{"color":"%s","name":"%s","kind":"%s","decimals":%s,"asset_id":"%s"}' \
    "${COLOR}" "${NAME}" "${PRIVACY}" "${DECIMALS}" "${ASSET_ID}")"
  POST_OUT="$(curl -sS --max-time 20 -o /tmp/issuer-post.body -w '%{http_code}' \
    -H 'Content-Type: application/json' -d "${POST_BODY}" \
    "${KERNEL_API_URL}/v1/known-tokens" 2>/dev/null || printf '000')"
  POST_BODY_TEXT="$(head -c 300 /tmp/issuer-post.body 2>/dev/null || printf '')"

  case "${POST_OUT}" in
    2*)
      log "   POST ${POST_OUT} — registered ${NAME} (${PRIVACY}) at ${DECIMALS} decimals, priced as ${ASSET_ID}"
      CREATED=$(( CREATED + 1 ))
      ;;
    # ── 409 IS THE NORMAL ANSWER ON A SEEDED KERNEL, AND IT IS STILL READ BACK ─
    # The name is UNIQUE and the kernel checks it before the colour, so with the seeded row
    # present this POST answers 409 EVERY time — including the very first run, immediately
    # after the patch above has given that row this stack's colour. That is the
    # genuine-idempotence case and it is what "success" looks like here; a 201 happens only on a
    # kernel that seeds no row under this name.
    #
    # It is still not taken at face value: read the registry back and compare colours.
    #   same colour  -> success.
    #   other colour -> HARD FAILURE with a dump. The UPDATE has already run and succeeded, so a
    #                   foreign colour under this name means something changed the row between
    #                   the patch and this POST, or the patch matched no row while another row
    #                   holds the name. Neither is something to paper over.
    409*)
      OWNER="$(registry_json)"
      OWNER_COLOR="$(row_field "${OWNER}" "${NAME}" token_color)"
      OWNER_DECIMALS="$(row_field "${OWNER}" "${NAME}" decimals)"
      if [ "${OWNER_COLOR}" = "${COLOR}" ]; then
        log "   POST 409 — ${NAME} already names ${COLOR} (decimals ${OWNER_DECIMALS:-<unreadable>}); nothing to do"
        ALREADY=$(( ALREADY + 1 ))
      else
        log "   the registry holds ${OWNER_COLOR:-<unreadable>} under the name ${NAME}, but this"
        log "   stack's colour is ${COLOR} — and the patch above reported ${PATCH_ROWS} row(s) updated."
        log "   ${POST_BODY_TEXT}"
        registry_dump "${OWNER}"
        die "${NAME} names a colour this stack did not issue"
      fi
      ;;
    # Loud and fatal. A 404 NOT_ENABLED means ENABLE_TOKEN_REGISTRY did not reach the kernel as
    # the literal string "true" (it parses THAT variable strictly), a 400 names an unknown
    # asset_id (should not happen — see the preflight above), and a stack whose book cannot name
    # its own tokens is a stack where every offer shows up as 64 hex characters.
    *)
      log "   POST ${POST_OUT}: ${POST_BODY_TEXT}"
      registry_dump "$(registry_json)"
      FAILED=$(( FAILED + 1 ))
      die "could not register ${NAME} ${COLOR}: HTTP ${POST_OUT}"
      ;;
  esac

  SUMMARY="${SUMMARY}${NAME}=${COLOR:0:12}… "
  # Re-read once per token so the clash check for the NEXT one sees the row this one wrote.
  REGISTRY_BEFORE="$(registry_json)"
done <<EOF
${TOKEN_LINES}
EOF

rm -f /tmp/issuer-post.body

# ── the read-back, all six at once ──────────────────────────────────────────
# The per-token checks above prove each POST landed; this proves the registry as a WHOLE is what
# this stack intends, which is the thing ./verify.sh asserts and the thing a reviewer wants in
# one line.
FINAL="$(registry_json)"
MISSING=""
for line in $(printf '%s\n' "${TOKEN_LINES}" | awk '{print $2}'); do
  NAME="${line}"
  WANT="$(printf '%s\n' "${TOKEN_LINES}" | grep "^ISSUER_TOKEN ${NAME} " | sed -n 's/.* id=\([0-9a-f]\{64\}\).*/\1/p' | head -1 || true)"
  GOT="$(row_field "${FINAL}" "${NAME}" token_color)"
  [ "${GOT}" = "${WANT}" ] || MISSING="${MISSING}${NAME}(want ${WANT:0:12}… got ${GOT:-absent}) "
done
if [ -n "${MISSING}" ]; then
  log "the kernel registry does not hold this stack's colours for: ${MISSING}"
  registry_dump "${FINAL}"
  die "the registry read-back failed"
fi

log "ISSUER_REGISTRAR_RESULT tokens=${TOKEN_COUNT} updated=${UPDATED} created=${CREATED} already=${ALREADY} failed=${FAILED}"
log "${SUMMARY}"
exit 0
