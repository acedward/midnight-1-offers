#!/usr/bin/env bash
# solver-frontend — the COW solver's read-only monitor site.
#
# `exec bun run start.solver-frontend.ts`. That root script is the pinned tree's ONE
# documented way to run the site, and it is a single process, so this container's PID 1 is
# the real workload and compose's SIGTERM reaches it.
#
# IT DOES NOT WAIT FOR THE SOLVER, and that is the entire point of the service.
# Every other entrypoint in this image waits for what it needs, because a solver that starts
# into a missing kernel is a bug. This one is the opposite: the moment anyone opens the
# monitor is the moment the solver is down, so an unreachable solver is a RENDERED STATE
# ("SOLVER UNREACHABLE", with the time it was last seen) and never a reason to refuse to
# start. A wait here would delete exactly the behaviour the service exists for — and
# compose/solver.yml's `depends_on` says the same thing structurally: the kernel, and nothing
# else.
#
# IT DOES NOT CALL adopt_contract_address EITHER. The site never names a token colour from
# the contract — it labels colours from the kernel's own `GET /v1/known-tokens` and falls
# back to short hex — so it has no reason to read the deployed identity, and the service does
# not mount the shared volume that holds it. Calling it here would block for
# CONTRACT_WAIT_TIMEOUT_S and then fail, which is a fifteen-minute way of saying "wrong
# dependency".
#
# THIS SCRIPT MUST NOT VALIDATE THE SITE'S OWN CONFIGURATION — the same rule
# entrypoint-solver.sh follows. `packages/solver-frontend/env.ts` resolves every boundary
# (SOLVER_FRONTEND_SOLVER_STATUS_URL, SOLVER_FRONTEND_SOLVER_STATUS_TOKEN,
# SOLVER_FRONTEND_ZSWAP_API and the optional host/port/relay/poll/history knobs) in one
# side-effect-free pass and exits 1 listing EVERY problem at once, before anything binds.
# That is this profile's fail-fast negative control; a pre-check here would shadow it, and
# the gate would then be proving that this shell script works, which is worth nothing.

# Consumed by log() in the sourced prelude, which shellcheck cannot see from here.
# shellcheck disable=SC2034
ROLE=solver-frontend
# shellcheck source=images/offerfiles-kernel/entrypoint-common.sh
. /usr/local/lib/offerfiles/entrypoint-common.sh

# "" IS NOT "unset". Compose cannot express "omit this variable" (`FOO: ${FOO}` renders as
# FOO=""), and the site's env resolver treats a PRESENT empty value as malformed rather than
# absent: an empty SOLVER_FRONTEND_POLL_MS fails the bounded-integer grammar instead of
# landing on 4000, and an empty SOLVER_FRONTEND_RELAY_HTTP_URL fails URL parsing instead of
# simply hiding the relay panel. So the genuinely OPTIONAL knobs are removed when blank.
#
# NONE of the three MANDATORY boundaries appears below. An empty one must reach
# `start.solver-frontend.ts` still empty so it is reported as missing — that is the fail-fast
# negative control, and softening it here would delete it.
unset_if_empty SOLVER_FRONTEND_HOST SOLVER_FRONTEND_PORT SOLVER_FRONTEND_RELAY_HTTP_URL \
               SOLVER_FRONTEND_POLL_MS SOLVER_FRONTEND_HISTORY_LIMIT

cd "${REPO_ROOT}" || die "no ${REPO_ROOT}"
log "starting the solver monitor (start.solver-frontend.ts) — its launch banner follows"
log "NOTE: it does NOT wait for the solver. An unreachable solver is a rendered state here."
exec bun run start.solver-frontend.ts
