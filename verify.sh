#!/usr/bin/env bash
#
# Assert the demo stack is not merely running but usable. Exit 0 = everything checked passed.
#
# Sections, in dependency order:
#   core        node RPC + finality advancing, indexer GraphQL on BOTH served paths tracking
#               the chain, proof-server accepting connections, postgres healthy
#   celestia    the offerfiles profile's DA devnet: producing blocks, blob round trip
#   kernel      /v1/health/sync current, the book endpoints, batcher health
#   frontend    the zswap-da SPA serves its assets and a browser-reachable /config.js
#   shielded-night  the dApp serves, /config.js carries THIS stack's contract address, the 11
#               circuits' ZK artifacts answer with binary, the on-chain verifier keys equal the
#               served ones, and a funded wallet completes both NIGHT <-> sNight round trips
#   solver      relay /tokens carries both dev colours, one connected solver, quote round trip
#
# Every optional section runs IF AND ONLY IF that profile's containers exist for this compose
# project, so `./verify.sh` needs no argument to do the right thing after any `./up.sh`.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"

CORE_ONLY=0
CELESTIA_MODE=auto
KERNEL_MODE=auto
FRONTEND_MODE=auto
SHIELDED_NIGHT_MODE=auto
SOLVER_MODE=auto

usage() {
  cat <<'EOF'
Usage: ./verify.sh [options]

Options:
  --core-only    only the node/indexer/proof-server/postgres checks; skip every optional
                 profile section
  --celestia     require the celestia section (fail if the profile is not up)
  --no-celestia  skip the celestia section even if the profile is up
  --kernel       require the kernel section (fail if the service is not up)
  --no-kernel    skip the kernel section even if the service is up
  --frontend     require the frontend section (fail if the profile is not up)
  --no-frontend  skip the frontend section even if the profile is up
  --shielded-night     require the shielded-night section (fail if the profile is not up)
  --no-shielded-night  skip the shielded-night section even if the profile is up
  --solver       require the solver section (fail if the profile is not up)
  --no-solver    skip the solver section even if the profile is up
  -h, --help     this text

Environment:
  ENV_FILE=<path>  verify a different stack instance (see .env.example)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --core-only)   CORE_ONLY=1; CELESTIA_MODE=off; KERNEL_MODE=off; FRONTEND_MODE=off; SHIELDED_NIGHT_MODE=off; SOLVER_MODE=off; shift ;;
    --celestia)    CELESTIA_MODE=on;  shift ;;
    --no-celestia) CELESTIA_MODE=off; shift ;;
    --kernel)      KERNEL_MODE=on;    shift ;;
    --no-kernel)   KERNEL_MODE=off;   shift ;;
    --frontend)    FRONTEND_MODE=on;  shift ;;
    --no-frontend) FRONTEND_MODE=off; shift ;;
    --shielded-night)    SHIELDED_NIGHT_MODE=on;  shift ;;
    --no-shielded-night) SHIELDED_NIGHT_MODE=off; shift ;;
    --solver)      SOLVER_MODE=on;    shift ;;
    --no-solver)   SOLVER_MODE=off;   shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown option: $1"; echo; usage; exit 2 ;;
  esac
done

require_docker
load_env
# This script reaches into containers with `dc exec` (postgres, proof-server). `dc` passes
# exactly the fragments named in PROFILES, and compose calls any container it has no
# definition for an ORPHAN — so naming only core would print "Found orphan containers (…)"
# on every exec as soon as a second profile is up. Name them all; nothing is started here.
use_all_profiles

FAILURES=0

# run_section <label> <sentinel service> <mode> <script> <how to bring it up>
#
# One implementation for every optional section. Presence is read off the containers rather
# than off a flag; `on` turns a missing profile into a failure, `auto` into a skip.
#
# A missing section script is a FAILURE, never a silent pass. During the phased build-out
# these scripts land with their profiles, and a verify.sh that quietly reported success for
# a section it could not run would be worse than useless.
run_section() {
  local label="$1" sentinel="$2" mode="$3" script="$4" hint="$5"
  [[ "$mode" == "off" ]] && return 0

  if ! service_present "$sentinel"; then
    if [[ "$mode" == "on" ]]; then
      echo
      err "--${label} was requested but no ${sentinel} container exists for project '${COMPOSE_PROJECT_NAME}'"
      dim "bring it up with: ${hint}"
      FAILURES=$(( FAILURES + 1 ))
    else
      echo
      dim "${label} not up — skipping (${hint} to include it)"
    fi
    return 0
  fi

  echo
  log "$label"
  if [[ ! -x "$REPO_ROOT/$script" ]]; then
    err "${label} is up but ${script} does not exist — the section cannot be verified"
    FAILURES=$(( FAILURES + 1 ))
    return 0
  fi
  if "$REPO_ROOT/$script"; then
    ok "${label} assertions passed"
  else
    err "${label} assertions failed"
    FAILURES=$(( FAILURES + 1 ))
  fi
}

# ── core ─────────────────────────────────────────────────────────────────────
CORE_PRESENT=0
service_present node && CORE_PRESENT=1

if (( ! CORE_PRESENT )); then
  echo
  warn "no core containers exist for project '${COMPOSE_PROJECT_NAME}'"
  info "this repository is at its P0 scaffold: the compose fragments are valid placeholders"
  info "and declare no services yet. Bring up a real stack once P1 lands, then re-run."
  info "nothing was verified."
  exit 0
fi

echo
log "core: node"
info "rpc ${NODE_RPC_URL}"
wait_node_rpc "$NODE_RPC_URL" 30 || FAILURES=$(( FAILURES + 1 ))
# Finality advancing is the real liveness signal: chain_getFinalizedHead keeps answering with
# the same hash forever when GRANDPA has stalled.
wait_finalized_advances "$NODE_RPC_URL" 120 || FAILURES=$(( FAILURES + 1 ))

BEST=$(node_best_height "$NODE_RPC_URL" || true)
FINAL=$(node_finalized_height "$NODE_RPC_URL" || true)
info "best=${BEST:-?}  finalized=${FINAL:-?}"

if service_present proof-server; then
  echo
  log "core: proof-server"
  # Reachable from the host on the published port…
  wait_tcp "$HOST_ADDR" "$PROOF_HOST_PORT" "proof-server" 30 || FAILURES=$(( FAILURES + 1 ))
  # …and actually READY, not merely listening. 8.1.0 serves /ready and /health; it binds its
  # port only after its proof-data fetch-and-verify completes, so a 200 here also means the
  # `proof-data` cache the pre-warm one-shot populated is present and usable.
  if [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
             "http://${HOST_ADDR}:${PROOF_HOST_PORT}/ready" 2>/dev/null)" == "200" ]]; then
    ok "proof-server /ready answers 200"
  else
    err "proof-server does not answer 200 on /ready"
    FAILURES=$(( FAILURES + 1 ))
  fi
  # The pre-warm is the ONLY writer of the cache, and the server mounts it read-only — so an
  # empty cache is not a slow first proof, it is an EROFS failure at prove time. Assert the
  # cache is non-empty rather than inferring it.
  # Counted with bash's globstar rather than `find`: this image ships GNU coreutils in /bin
  # but NOT findutils, so `find` is absent (calling it exits 127). Everything used here is a
  # bash builtin. `|| true` because a failed exec must be reported by the assertion below
  # rather than killing the whole verify run through errexit.
  # shellcheck disable=SC2016  # single quotes are REQUIRED: $p and $n must be expanded by
  # the container's bash, not by this one. Double quotes would expand them here, to nothing.
  PP_FILES=$(dc exec -T proof-server /bin/bash -c \
    'shopt -s globstar nullglob dotglob; n=0; for p in /proof-data/**; do [[ -f "$p" ]] && n=$((n+1)); done; echo "$n"' \
    2>/dev/null | tr -dc '0-9' || true)
  if [[ -n "${PP_FILES:-}" ]] && (( PP_FILES > 0 )); then
    ok "proof-data cache holds ${PP_FILES} file(s)"
  else
    err "proof-data cache is empty or unreadable — the pre-warm one-shot did not populate it"
    FAILURES=$(( FAILURES + 1 ))
  fi
fi

if service_present postgres; then
  echo
  log "core: postgres"
  if [[ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
        "$(docker ps -aq --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" \
                         --filter "label=com.docker.compose.service=postgres" | head -1)" \
        2>/dev/null)" == "healthy" ]]; then
    ok "postgres healthy"
  else
    err "postgres is not healthy"
    FAILURES=$(( FAILURES + 1 ))
  fi

  # Container health is not the same as a usable database. Query the REAL consumer database
  # as the REAL consumer role — this is what P2's kernel will do, and it is the difference
  # between "a server is running" and "the offer book has somewhere to live".
  if [[ "$(dc exec -T postgres psql -U "$OFFERFILES_PG_USER" -d "$OFFERFILES_PG_DB" \
             -tAc 'select 1' 2>/dev/null | tr -d '[:space:]')" == "1" ]]; then
    ok "database '${OFFERFILES_PG_DB}' answers as role '${OFFERFILES_PG_USER}'"
  else
    err "cannot query database '${OFFERFILES_PG_DB}' as role '${OFFERFILES_PG_USER}'"
    FAILURES=$(( FAILURES + 1 ))
  fi

  # pg_ivm is the whole reason this is not a stock postgres image. Without it the kernel
  # either refuses to start or (with ALLOW_NO_PG_IVM=true) silently drops to a read path its
  # own docs call sharply degraded — so its absence must fail here, loudly, not at P2.
  if [[ "$(dc exec -T postgres psql -U "$OFFERFILES_PG_USER" -d "$OFFERFILES_PG_DB" \
             -tAc "select extversion from pg_extension where extname='pg_ivm'" 2>/dev/null | tr -d '[:space:]')" != "" ]]; then
    ok "pg_ivm extension installed in '${OFFERFILES_PG_DB}'"
  else
    err "pg_ivm is NOT installed in '${OFFERFILES_PG_DB}' — the kernel needs it (see images/postgres)"
    FAILURES=$(( FAILURES + 1 ))
  fi
fi

if service_present indexer; then
  echo
  log "core: indexer"
  info "graphql ${INDEXER_GQL_URL}"
  if wait_indexer_graphql "$INDEXER_GQL_URL" 60; then
    IH=$(indexer_height "$INDEXER_GQL_URL" || true)
    info "indexer height=${IH:-?}  (node best=${BEST:-?})"
    if [[ -n "${IH:-}" ]] && (( IH > 0 )); then
      ok "indexer has indexed at least one block"
    else
      err "indexer height is 0 or unreadable"
      FAILURES=$(( FAILURES + 1 ))
    fi
    # The indexer trails the node by a few blocks under normal operation; only a large,
    # persistent gap is a problem, so this is reported rather than asserted.
    if [[ -n "${IH:-}" && -n "${BEST:-}" ]]; then
      GAP=$(( BEST - IH ))
      (( GAP > 20 )) && warn "indexer is ${GAP} blocks behind the node"
    fi

    # indexer-standalone 4.3.3 serves the SAME schema at /api/v3/graphql and /api/v4/graphql.
    # Consumers in this stack are split across the two paths, so both are asserted: a future
    # version that drops one would otherwise break exactly half the stack, silently.
    for path in /api/v3/graphql /api/v4/graphql; do
      if [[ "$(graphql "http://${HOST_ADDR}:${INDEXER_HOST_PORT}${path}" '{ block { height } }' || true)" == *'"height"'* ]]; then
        ok "indexer answers on ${path}"
      else
        err "indexer does not answer on ${path}"
        FAILURES=$(( FAILURES + 1 ))
      fi
    done

    # A restart policy makes an unattended demo recoverable, but a verification gate must not
    # let that resilience mask a crash.
    INDEXER_CID=$(docker ps -aq \
      --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" \
      --filter "label=com.docker.compose.service=indexer" | head -n 1)
    INDEXER_RESTARTS=$(docker inspect -f '{{.RestartCount}}' "$INDEXER_CID" 2>/dev/null || echo unreadable)
    if [[ "$INDEXER_RESTARTS" == "0" ]]; then
      ok "indexer restart count is zero"
    else
      err "indexer restart count is ${INDEXER_RESTARTS}"
      FAILURES=$(( FAILURES + 1 ))
    fi
  else
    FAILURES=$(( FAILURES + 1 ))
  fi
fi

# ── optional profiles ────────────────────────────────────────────────────────
if (( ! CORE_ONLY )); then
  run_section celestia celestia "$CELESTIA_MODE" scripts/verify-celestia.sh "./up.sh --with offerfiles"
  run_section kernel   kernel   "$KERNEL_MODE"   scripts/verify-kernel.sh   "./up.sh --with offerfiles"
  run_section frontend frontend "$FRONTEND_MODE" scripts/verify-frontend.sh "./up.sh --with frontend"
  # The sentinel is the WEB service, not the deploy one-shot: the one-shot exits, and a stack
  # whose page is gone but whose exited one-shot lingers must not report a passing section.
  run_section shielded-night shielded-night "$SHIELDED_NIGHT_MODE" \
    scripts/verify-shielded-night.sh "./up.sh --with shielded-night"
  run_section solver   solver   "$SOLVER_MODE"   scripts/verify-solver.sh   "./up.sh --with offerfiles --with solver"
fi

echo
if (( FAILURES == 0 )); then
  ok "verify.sh: all checks passed"
  exit 0
fi
err "verify.sh: ${FAILURES} check(s) failed"
exit 1
