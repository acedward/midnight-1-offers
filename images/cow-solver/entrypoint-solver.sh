#!/usr/bin/env bash
# solver — the COW posted-price solver as its own component, in EXECUTION mode.
#
# `exec bun run start.solver.ts`. That root script is the branch's ONE documented way to run
# the solver; it is deliberately absent from `start:mainnet`, and it is not the orchestrator
# (which would kill the very chain services this stack runs as siblings — see
# images/offerfiles-kernel/Dockerfile for the full reasoning).
#
# THIS SCRIPT MUST NOT VALIDATE THE SOLVER'S OWN CONFIGURATION.
# `packages/solver/src/launch.ts` resolves all seven mandatory boundaries
# (MIDNIGHT_NETWORK_ID, ZSWAP_API, SOLVER_RELAY_WS_URL, SOLVER_RELAY_HTTP_URL,
# SOLVER_RELAY_AUTH_TOKEN, SOLVER_JOURNAL_PATH, SOLVER_SEED) in one side-effect-free pass and
# exits 1 listing EVERY problem at once, before a wallet, a socket or a journal is touched.
# That is this deployment's fail-fast negative control. A pre-check here would shadow it: the
# gate would then be proving that this shell script works, which is worth nothing. The only
# variables checked below are the ones THIS SCRIPT needs in order to wait for dependencies.

# Consumed by log() in the sourced prelude, which shellcheck cannot see from here.
# shellcheck disable=SC2034
ROLE=solver
# shellcheck source=images/offerfiles-kernel/entrypoint-common.sh
. /usr/local/lib/offerfiles/entrypoint-common.sh

require_env ZSWAP_API SOLVER_JOURNAL_PATH

# "" IS NOT "unset", and here it is worse than usual. The solver's env parsers are
# deliberately strict: `SOLVER_SUPPORTED_PAIRS=""` is a PRESENT value that fails JSON
# parsing, and `SOLVER_DRY_RUN=""` fails the exactly-"true"/"false" grammar — so an operator
# who merely left a knob blank in .env gets a startup failure instead of the default. Compose
# cannot express "omit this variable" (`FOO: ${FOO}` renders as FOO=""), so genuinely
# optional knobs are removed here.
#
# NONE of the solver's seven mandatory boundaries appear below. An empty one must reach
# `launch.ts` still empty so it is reported as missing — that is the fail-fast negative
# control this deployment relies on, and softening it here would delete it.
unset_if_empty SOLVER_LADDER_CONFIG SOLVER_SUPPORTED_PAIRS SOLVER_MIN_JOB_OUTPUT \
               SOLVER_DRY_RUN SOLVER_ENABLED

# The journal is fail-closed SQLite on a per-instance volume, and `runSolver` opens it rather
# than creating its directory. `launch.ts` has already been shown the same value and rejects
# a relative or `:memory:` path itself, so this only prepares the path it accepted.
mkdir -p "$(dirname "${SOLVER_JOURNAL_PATH}")"

# The solver mirrors the kernel's book and rebuilds maker bytes from it, so it needs the same
# contract identity every other offer-files container adopts.
adopt_contract_address

wait_http "${ZSWAP_API}/v1/health" "kernel API" "${KERNEL_WAIT_TIMEOUT_S:-600}" \
  || die "the kernel API never answered — the solver has no book to mirror"

# The relay does NOT have to be up: the solver's relay client retries the socket on its own,
# and making this fatal would turn a relay restart into a solver crash loop. Waiting anyway
# makes the first ladder push immediate instead of one reconnect delay later.
#
# GET /tokens, because the relay has no /health route. It answers 200 with an empty list when
# no solver is connected, which is precisely the state we are waiting to leave.
if [ -n "${SOLVER_RELAY_HTTP_URL:-}" ]; then
  wait_http "${SOLVER_RELAY_HTTP_URL}/tokens" "relay HTTP" "${RELAY_WAIT_TIMEOUT_S:-300}" \
    || log "WARNING: the relay is not reachable yet — the WS client will keep retrying"
fi

cd "${REPO_ROOT}" || die "no ${REPO_ROOT}"
log "starting the solver (start.solver.ts) — its launch banner follows"
exec bun run start.solver.ts
