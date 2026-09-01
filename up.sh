#!/usr/bin/env bash
#
# Bring up the demo stack and block until every service is actually usable.
#
# "Actually usable" is stricter than "docker says healthy":
#   node          RPC answers chain_getBlockHash[1]  → the chain is producing blocks
#   indexer       GraphQL answers a block query      → the API is serving, not just booting
#   proof-server  the port accepts a TCP connection  → nothing inside the image can probe it
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"

PROFILES=""
DO_PULL=0
DO_BUILD=0
WANT_ALL=0
CONVERGE=0

usage() {
  # The profile list is GENERATED from compose/, never typed: a hand-maintained list in the
  # help text is the first thing to drift when a fragment is added or removed.
  local avail
  avail="$(available_profiles | tr '\n' ' ')"
  cat <<EOF
Usage: ./up.sh [options]

Brings up the core Midnight 1.x stack (node + indexer + proof-server + postgres) and waits
until each is serving. Reads .env for image pins and host ports (see .env.example).

PROFILES — there are exactly four, and a profile IS a compose fragment in compose/, named
after the file. No compose \`profiles:\` key is used anywhere in this repository.

  core           ALWAYS on. midnight-node ${NODE_VERSION}, indexer-standalone ${INDEXER_VERSION},
                 proof-server ${PROOF_VERSION}, and the shared PostgreSQL.
  offerfiles     Celestia DA devnet, the contract deploy one-shot, the offer-files kernel
                 (:${KERNEL_HOST_PORT}) and the batcher (:${BATCHER_HOST_PORT}).
  frontend       the zswap-da SPA (:${FRONTEND_HOST_PORT}).
  solver         the Midnight Intents relay (:${RELAY_HTTP_HOST_PORT} HTTP, :${RELAY_WS_HOST_PORT} WS), the COW solver
                 in execution mode, and the intents browser UI (:${INTENTS_UI_HOST_PORT}).
                 BUILDS FROM A PRIVATE CLONE YOU SUPPLY — see RELAY_SOURCE_DIR below.

Options:
  --with <profile>   ALSO bring up an optional profile; repeatable, and additive — see below.
                     An unknown name is an error, not a no-op.
                     Available now: ${avail}
  --all              bring up every shipped profile in compose/.
  --converge         the opposite of additive: bring up EXACTLY core + the named profiles and
                     STOP any other profile that is currently up. \`./up.sh --converge\` on its
                     own therefore means "core alone". Every profile it is about to stop is
                     named before it happens.
  --pull             docker compose pull before starting.
  --build            docker compose build before starting (for the locally-built images).
  -h, --help         this text.

\`--with\` is ADDITIVE: any profile that already has containers in this compose project is
folded back into the bring-up, so \`./up.sh --with offerfiles\` on a stack where \`frontend\` is
running brings up Celestia and leaves the SPA alone. The profiles carried over are named on
every run. To take a profile down, use ./down.sh (everything) or --converge without it.

Orphan cleanup is unaffected: compose still runs with --remove-orphans, and a container whose
service is no longer declared by ANY fragment is still removed. Only whole profiles that are
genuinely up are protected.

Environment:
  ENV_FILE=<path>          use a different env file than ./.env — this is how two stacks run
                           side by side on one machine:
                              ENV_FILE=.env.test ./up.sh
  RELAY_SOURCE_DIR=<path>  REQUIRED by the solver profile. The relay and intents UI are built
                           from a PRIVATE repository whose source is never carried here; point
                           this at your own clone. up.sh verifies it is at the pinned commit
                           with a clean tree before any build starts. Every other profile
                           needs no credential at all.

Examples:
  ./up.sh                       # core stack, plus whatever profiles are already up
  ./up.sh --with offerfiles     # …and Celestia + kernel + batcher
  ./up.sh --with frontend       # …and the zswap-da SPA
  ./up.sh --all                 # everything (needs RELAY_SOURCE_DIR for solver)
  ./up.sh --converge            # core ONLY: stop every optional profile that is up
  ENV_FILE=.env.ci ./up.sh      # a second, port-shifted instance
EOF
}

# A `--with` name that has no fragment must FAIL. Accepting it and quietly dropping it later
# means the stack comes up as bare core and only fails much later, as `no such service: …`.
add_profile() {
  local p="$1" pend
  if [[ ! -f "$REPO_ROOT/compose/$p.yml" ]]; then
    err "unknown profile: $p"
    info "available now: $(available_profiles | tr '\n' ' ')"
    pend="$(pending_profiles | tr '\n' ' ')"
    [[ -n "${pend// /}" ]] && info "not built yet, coming with ${FUTURE_PROFILES_BLOCKER}: ${pend}"
    exit 2
  fi
  PROFILES="$PROFILES $p"
}

# --help must work before load_env has run, and the usage text quotes the port block, so the
# defaults are applied first. This is a read-only operation: no docker, no containers.
HELP_ONLY=0
for arg in "$@"; do [[ "$arg" == "-h" || "$arg" == "--help" ]] && HELP_ONLY=1; done
if (( HELP_ONLY )); then
  load_env >/dev/null 2>&1 || true
  usage
  exit 0
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with)   add_profile "${2:?--with needs a profile name}"; shift 2 ;;
    --with=*) add_profile "${1#*=}"; shift ;;
    --all)
      while IFS= read -r p; do PROFILES="$PROFILES $p"; done < <(available_profiles)
      WANT_ALL=1
      shift ;;
    --converge) CONVERGE=1; shift ;;
    --pull)  DO_PULL=1; shift ;;
    --build) DO_BUILD=1; shift ;;
    *) err "unknown option: $1"; echo; exit 2 ;;
  esac
done

export PROFILES
require_docker
load_env
# Nothing starts against a weak identity. load_env only warns (so `./down.sh` can always
# clean up); this is the fatal form, and it runs before a single container is created.
assert_image_pins

# ── `--with` is ADDITIVE ─────────────────────────────────────────────────────
#
# Everything already up in this compose project is folded back into PROFILES, so bringing up
# a new profile cannot stop the ones that are running. Without this, compose is given only
# core + the named fragments and `--remove-orphans` removes the rest — silently, mid-command.
#
# `--remove-orphans` stays. With every live profile named, the only containers it can still
# remove are those of a service no longer declared by any fragment.
#
# It has to run after load_env: the lookup is by COMPOSE_PROJECT_NAME, which the env file sets.
CARRIED=""
STOPPING=""
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  if (( CONVERGE )); then
    [[ " $PROFILES " == *" $p "* ]] || STOPPING="$STOPPING $p"
  else
    [[ " $PROFILES " == *" $p "* ]] && continue
    PROFILES="$PROFILES $p"
    CARRIED="$CARRIED $p"
  fi
done < <(running_profiles)
export PROFILES

log "demo stack: project '${COMPOSE_PROJECT_NAME}'"
# Print the readable version AND the digest that is the actual identity: a version alone
# cannot be checked against anything, and a bare hash tells an operator nothing.
info "images   node=${NODE_VERSION} ${NODE_IMAGE#*@}"
info "         indexer=${INDEXER_VERSION} ${INDEXER_IMAGE#*@}"
info "         proof=${PROOF_VERSION} ${PROOF_IMAGE#*@}"
info "ports    node=${HOST_ADDR}:${NODE_HOST_PORT}  indexer=${HOST_ADDR}:${INDEXER_HOST_PORT}  proof=${HOST_ADDR}:${PROOF_HOST_PORT}"
[[ -n "${PROFILES// /}" ]] && info "profiles core${PROFILES// /, }"
# Say what was carried over and what is about to be stopped. Both directions are named out
# loud: a profile that gets stopped silently, mid-command, is the surprise --converge exists
# to make explicit.
[[ -n "${CARRIED// /}" ]] && info "kept     already up, so left running:${CARRIED}"
if (( CONVERGE )); then
  if [[ -n "${STOPPING// /}" ]]; then
    warn "--converge: STOPPING the profile(s) not named this time:${STOPPING}"
  else
    dim "--converge: no other profile is up, so nothing will be stopped"
  fi
fi
# Name what a partial profile does and does not include, every time. Left unsaid, a profile
# that comes up with no services reads as a broken build rather than as a scaffold.
for p in core ${PROFILES:-}; do
  if note="$(partial_profile_note "$p" 2>/dev/null)"; then
    info "note     ${p} is PARTIAL: ${note}"
  fi
done
if (( WANT_ALL )); then
  PENDING="$(pending_profiles | tr '\n' ' ')"
  if [[ -n "${PENDING// /}" ]]; then
    info "not built yet, so --all skipped them (coming with ${FUTURE_PROFILES_BLOCKER}): ${PENDING}"
  fi
fi

# ── the PRIVATE relay source, verified BEFORE anything is built ──────────────
# The solver profile's relay and intents UI build from an operator-local clone of a private
# repository (spec FR-11). Its identity cannot be guaranteed by a pinned fetch the way every
# other source in this stack is, so it is verified here — at the pinned commit, clean tree —
# before a single build layer runs. The check arms itself when compose/solver.yml declares
# services; while the fragment is a placeholder there is nothing to build.
if [[ " $PROFILES " == *" solver "* ]]; then
  if relay_source_required; then
    assert_relay_source || exit 1
  else
    dim "solver fragment declares no services yet — RELAY_SOURCE_DIR not needed until P4"
  fi
fi

# Pre-create the per-project host cache directory some services bind-mount. Letting docker
# create a missing bind-mount source races with the first container that writes there.
mkdir -p "$REPO_ROOT/.cache/${COMPOSE_PROJECT_NAME}"

if (( DO_PULL )); then
  log "pulling images"
  dc pull
fi
if (( DO_BUILD )); then
  log "building local images"
  if [[ "${COMPOSE_PARALLEL_LIMIT:-}" == "1" ]]; then
    # Compose v5 delegates one multi-service `build` to a single Bake graph, whose internal
    # targets still execute concurrently even when COMPOSE_PARALLEL_LIMIT=1. Issue one
    # service build at a time when strict serialisation was requested. Image-only services
    # are harmless (`No services to build`, exit 0).
    while IFS= read -r service; do
      [[ -n "$service" ]] || continue
      info "build service ${service}"
      dc build "$service"
    done < <(dc config --services)
  else
    dc build
  fi
fi

# While every fragment is still a placeholder there is nothing to start, and `docker compose
# up` on an empty service set is a no-op that reads as success. Say what actually happened.
if [[ -z "$(dc config --services 2>/dev/null | tr -d '[:space:]')" ]]; then
  echo
  warn "no services are declared yet — this repository is at its P0 scaffold"
  info "the compose fragments are valid placeholders; services land in P1 (core), P2"
  info "(offerfiles), P3 (frontend) and P4 (solver). Nothing was started."
  exit 0
fi

FAILED=0
log "starting containers"
if ! dc up -d --remove-orphans; then
  FAILED=1
  echo
  err "docker compose up failed. Container state and last 40 log lines follow:"
  dc ps -a || true
  dc logs --tail=40 || true
  echo
  info "the stack is left running for inspection — './down.sh' to stop it"
  exit 1
fi

log "waiting for services"
# Postgres first, and cheaply: it has no dependencies, its healthcheck already proves the
# consumer database exists (not merely that a server answers), and P2's kernel cannot start
# without it. A database failure found here costs seconds; found after the chain is up it
# costs the whole bring-up.
if service_present postgres; then
  wait_compose_healthy postgres "$POSTGRES_WAIT_TIMEOUT" || FAILED=1
fi

# Node next: the indexer cannot make progress before the chain produces blocks, and a node
# failure is the cheapest one to diagnose.
if (( ! FAILED )) && service_present node; then
  wait_compose_healthy node "$NODE_WAIT_TIMEOUT" || FAILED=1
  (( FAILED )) || wait_node_rpc "$NODE_RPC_URL" "$NODE_WAIT_TIMEOUT" || FAILED=1
  # Answering RPC is not the same as being transactable. Until finality moves off genesis a
  # wallet refuses to build anything, so a funding or deploy run started right after up.sh
  # would fail. Gate on it here, once, instead of making every consumer rediscover it.
  (( FAILED )) || wait_finalized_height "$NODE_RPC_URL" 1 "$NODE_WAIT_TIMEOUT" || FAILED=1
fi

# The proof-server is independent of the chain, so probe it while the indexer catches up.
#
# BOTH probes, because they prove different things. The container healthcheck asks the server
# itself (`GET /ready` over bash's /dev/tcp) and — since 8.1.0 binds its port only after its
# proof-data fetch-and-verify completes — a healthy container means the cache is warm. The
# host-side TCP wait then proves the PUBLISHED PORT MAPPING works, which nothing inside the
# container can tell us. A stack whose proof server is ready but unreachable from the host is
# a stack where every browser proof fails.
if (( ! FAILED )) && service_present proof-server; then
  wait_compose_healthy proof-server "$PROOF_WAIT_TIMEOUT" || FAILED=1
  (( FAILED )) || wait_tcp "$HOST_ADDR" "$PROOF_HOST_PORT" "proof-server" "$PROOF_WAIT_TIMEOUT" || FAILED=1
fi

if (( ! FAILED )) && service_present indexer; then
  wait_compose_healthy indexer "$INDEXER_WAIT_TIMEOUT" || FAILED=1
  (( FAILED )) || wait_indexer_graphql "$INDEXER_GQL_URL" "$INDEXER_WAIT_TIMEOUT" || FAILED=1
fi

# Optional profiles, after the core stack they depend on. Each waits on the thing that proves
# the profile is usable, not merely started — same rule as the core services. P1–P4 extend
# these blocks as their services land.
if (( ! FAILED )) && [[ " $PROFILES " == *" offerfiles "* ]] && service_present celestia; then
  wait_compose_healthy celestia "$CELESTIA_WAIT_TIMEOUT" || FAILED=1
fi
if (( ! FAILED )) && [[ " $PROFILES " == *" offerfiles "* ]] && service_present kernel; then
  wait_compose_healthy kernel "$KERNEL_WAIT_TIMEOUT" || FAILED=1
fi
if (( ! FAILED )) && [[ " $PROFILES " == *" frontend "* ]] && service_present frontend; then
  wait_compose_healthy frontend "$FRONTEND_WAIT_TIMEOUT" || FAILED=1
fi
if (( ! FAILED )) && [[ " $PROFILES " == *" solver "* ]] && service_present relay; then
  wait_compose_healthy relay "$RELAY_WAIT_TIMEOUT" || FAILED=1
fi
if (( ! FAILED )) && [[ " $PROFILES " == *" solver "* ]] && service_present solver; then
  wait_compose_healthy solver "$SOLVER_WAIT_TIMEOUT" || FAILED=1
fi

if (( FAILED )); then
  echo
  err "stack did not come up. Last 40 log lines per service:"
  dc logs --tail=40 || true
  echo
  info "the stack is left running for inspection — './down.sh' to stop it"
  exit 1
fi

echo
log "stack is up"
service_present node         && info "node RPC          ${NODE_RPC_URL}"
service_present indexer      && info "indexer GraphQL   ${INDEXER_GQL_URL}"
service_present proof-server && info "proof server      http://${HOST_ADDR}:${PROOF_HOST_PORT}"
service_present kernel       && info "offer-files API   ${KERNEL_URL}"
service_present batcher      && info "batcher           ${BATCHER_URL}"
service_present frontend     && info "zswap-da SPA      http://${HOST_ADDR}:${FRONTEND_HOST_PORT}"
service_present relay        && info "intents relay     ${RELAY_URL}   (solver WS :${RELAY_WS_HOST_PORT})"
service_present intents-ui   && info "intents UI        http://${HOST_ADDR}:${INTENTS_UI_HOST_PORT}"
echo
info "next: ./verify.sh    (assert the stack is usable, not merely running)"
info "      ./down.sh -v   (stop and wipe all chain/indexer/kernel state)"
