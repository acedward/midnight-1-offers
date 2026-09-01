#!/usr/bin/env bash
# kernel — the offer-files SYNC NODE and /v1 API. ONE process, PID 1.
#
# `exec bun run packages/node/main.dev.ts`. NOT `bun run dev`, which is the orchestrator:
# `launchMidnight()`/`launchCelestia()` open with `stopProcessAtPort [9944, 8088, 6300, 26657,
# 26658, 3334]` and would kill the very services this container was pointed at, and the
# orchestrator ALSO forces `env: { PGLITE: "true" }` onto the sync node (start.dev.ts) — which
# the process manager merges as `{ ...process.env, ...config.env }`, so config.env WINS and
# every DB_* variable below would be silently ignored. Running main.dev.ts directly is the only
# way this container's Postgres configuration is honoured at all.
#
# `.dev.ts` and not `.preview.ts`/`.mainnet.ts`: "dev" names the target NETWORK. The others
# resolve hosted endpoints and `check-env.ts` gates them on `MIDNIGHT_NETWORK_ID=preview`.
#
# ONE MAIN-SPECIFIC TRAP, and it is why adopt_contract_address copies a file rather than just
# exporting a variable: `packages/node/config.dev.ts` reads the contract address as
# `midnightContract!.contractAddress` with NO env fallback (config.preview.ts has one;
# config.dev.ts does not). `readMidnightContract()` resolves a HARD-CODED path —
# `packages/contracts-midnight/contract-offer-files.<network>.json` — and additionally requires
# the compiled `contract-offer-files/src/managed/compiler/contract-info.json` to exist. Setting
# MIDNIGHT_CONTRACT_ADDRESS alone does NOT work here: that override is applied only AFTER the
# file read succeeds. The file is the handoff; the variable is a convenience on top of it.

# Consumed by log() in the sourced prelude, which shellcheck cannot see from here.
# shellcheck disable=SC2034
ROLE=kernel
# shellcheck source=images/offerfiles-kernel/entrypoint-common.sh
. /usr/local/lib/offerfiles/entrypoint-common.sh

require_env MIDNIGHT_NETWORK_ID MIDNIGHT_NODE_HTTP MIDNIGHT_INDEXER_HTTP \
            MIDNIGHT_INDEXER_WS MIDNIGHT_PROOF_SERVER_URL \
            CELESTIA_RPC_URL \
            DB_HOST DB_PORT DB_NAME DB_USER DB_PW

load_celestia_env

# ── the store: real PostgreSQL, never the embedded one ───────────────────────
# PGLITE DEFAULTS TO **TRUE** in @effectstream/utils' config registry, so omitting it does not
# mean "use Postgres" — it means "use an embedded store this repository does not have". Worse,
# `getConnection()` skips the password entirely when PGLITE is truthy and caps the pool at one
# connection, so a half-configured container fails as an auth error against the wrong server
# rather than as the configuration mistake it is.
#
# The value is checked for the LITERAL string "false" and not with a loose truthiness test,
# because upstream is inconsistent about it: `ENV.getBoolean` treats anything outside
# true|t|1|yes|y as false, but the orchestrator's PGlite launcher compares strictly to "false".
# `PGLITE=0` would therefore disable the connection setting and still spawn an embedded store.
# Requiring the exact string removes the whole class.
if [ "${PGLITE:-}" != "false" ]; then
  log "PGLITE must be exactly the string 'false' (got '${PGLITE:-<unset>}')"
  log "It DEFAULTS TO TRUE upstream, and this repository has no PGLite anywhere: the kernel"
  log "runs against the shared 'postgres' service. See compose/offerfiles.yml."
  exit 78
fi

# ALLOW_NO_PG_IVM is a real downgrade, not a compatibility shim: without pg_ivm the engine
# falls back to plain SQL views over the trigger-maintained tables, which upstream's own docs
# describe as degrading sharply on high-cardinality data. The shared postgres image compiles
# pg_ivm in and its initdb creates the extension in this database, so the flag should never be
# needed here. Say so loudly if somebody sets it rather than letting the stack quietly run the
# degraded read path.
case "${ALLOW_NO_PG_IVM:-}" in
  ""|false|False|FALSE|0|no|No|NO) : ;;
  *) log "WARNING: ALLOW_NO_PG_IVM=${ALLOW_NO_PG_IVM} — the kernel will accept a database"
     log "WARNING: WITHOUT pg_ivm and use the DEGRADED plain-view strategy. This stack's"
     log "WARNING: postgres image ships pg_ivm; you almost certainly do not want this." ;;
esac

wait_tcp "${DB_HOST}" "${DB_PORT}" "postgres" "${DB_WAIT_TIMEOUT_S:-300}" \
  || die "postgres never accepted a connection at ${DB_HOST}:${DB_PORT}"

# ── prove the DATABASE is usable, not merely that the port answers ───────────
# A TCP probe passes against a server that will reject this role, reject this database, or
# lack the extension. All three then surface much later, from inside the runtime, as a stack
# trace that names @effectstream internals rather than the deployment mistake.
#
# pg_ivm in particular is a PER-DATABASE object. "Compiled into the image" is not "created in
# MY database": the kernel's own probe is a best-effort `CREATE EXTENSION IF NOT EXISTS pg_ivm`
# wrapped in a bare try/catch, so when the app role is not superuser (it is not, by design)
# and initdb did not pre-create the extension in THIS database, the create silently fails, the
# pg_extension lookup returns false, and startup aborts. Catch that here, with the fix in the
# message.
#
# Run from packages/database: `pg` is that workspace member's dependency and bun does not
# hoist it to /app/node_modules, so `require("pg")` resolves from there and nowhere else.
log "probing ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME} for pg_ivm"
# The `$1` below is a POSTGRES placeholder, not a shell parameter — the JS is passed to bun
# verbatim and must not be interpolated here.
# shellcheck disable=SC2016
PGIVM="$(cd "${REPO_ROOT}/packages/database" && bun -e '
  const pg = require("pg");
  const client = new pg.Client({
    host: process.env.DB_HOST,
    port: Number(process.env.DB_PORT),
    user: process.env.DB_USER,
    password: process.env.DB_PW,
    database: process.env.DB_NAME,
    connectionTimeoutMillis: 10000,
  });
  await client.connect();
  const { rows } = await client.query(
    "SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = $1) AS present", ["pg_ivm"],
  );
  await client.end();
  process.stdout.write(rows[0] && rows[0].present ? "yes" : "no");
')" || die "could not connect to ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME} — check OFFERFILES_PG_USER / OFFERFILES_PG_PASSWORD / OFFERFILES_PG_DB"

if [ "${PGIVM}" = "yes" ]; then
  log "pg_ivm present in ${DB_NAME} — the kernel will use the incremental-view strategy"
else
  log "pg_ivm is NOT installed in database '${DB_NAME}'."
  log "The kernel aborts on this unless ALLOW_NO_PG_IVM is set, and setting it silently"
  log "downgrades the read path. The shared postgres image is supposed to create the"
  log "extension in this database from its initdb script, as the superuser — the app role"
  log "is deliberately not one, and pg_ivm is not a trusted extension."
  log "Fix: ./down.sh -v and bring the stack up again so initdb re-runs on an empty volume."
  [ "${PGIVM}" = "no" ] && exit 78
fi

adopt_contract_address

wait_node_block "${MIDNIGHT_NODE_HTTP}" 1 "${NODE_BLOCK_TIMEOUT_S:-600}" \
  || die "midnight-node produced no block"
wait_http "${MIDNIGHT_INDEXER_HTTP}" "indexer" "${INDEXER_WAIT_TIMEOUT_S:-300}" \
  || die "indexer never answered"
wait_http "${MIDNIGHT_PROOF_SERVER_URL}" "proof-server" "${PROOF_WAIT_TIMEOUT_S:-300}" \
  || die "proof-server never answered"
wait_http "${CELESTIA_RPC_URL}" "celestia bridge" "${CELESTIA_WAIT_TIMEOUT_S:-600}" \
  || die "the Celestia DA RPC never answered"

cd "${REPO_ROOT}" || die "no ${REPO_ROOT}"
log "starting the sync node and /v1 API on :${EFFECTSTREAM_API_PORT:-9999} (network ${NETWORK_ID})"
exec bun run packages/node/main.dev.ts
