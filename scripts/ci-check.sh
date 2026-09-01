#!/usr/bin/env bash
#
# One command that proves this stack works end to end, on ports that cannot collide with
# anything else on the machine, and leaves nothing behind afterwards.
#
#   ./scripts/ci-check.sh                # every profile that exists, brought up and verified
#   ./scripts/ci-check.sh --static-only  # the offline gates only: no Docker daemon, seconds
#   ./scripts/ci-check.sh --core-only    # core stack only
#   ./scripts/ci-check.sh --with solver  # specific profiles instead of --all
#
# The steps, in order:
#   1. static      leak scan, artifact-decision matrix, rendered compose pins  (OFFLINE)
#   2. up          the requested profiles, blocking until each is genuinely usable
#   3. verify      verify.sh
#   4. pins        verify-source-pins.sh against the images that are actually running
#   5. down -v     full teardown, then ASSERT that nothing survived
#
# Step 1 is the one to run before every push. It needs no daemon, no network and no
# credential, and it is where the PRIVATE-SOURCE LEAK GATE lives: this repository is public
# and `shieldedtech/midnight-intents-swaps` is not, so "did anything of theirs get committed"
# is checked before anything else is even considered.
#
# Three properties this has that a hand-run sequence does not:
#
#   * It never touches ./.env or the default ports. Everything runs against a generated env
#     file, so a CI run cannot disturb (or be disturbed by) a stack somebody left up.
#   * It tears down on every exit path — failure, Ctrl-C, or SIGTERM — because up.sh
#     deliberately leaves a failed stack running for inspection, which is right for a human
#     and wrong for CI.
#   * The teardown is ASSERTED, not assumed. Containers, networks and volumes are counted by
#     compose-project label AND by name prefix: a volume created outside compose carries no
#     project label at all, so a label-only count can report a clean teardown while something
#     survives.
#
set -uo pipefail   # deliberately NOT -e: every step's failure is handled and reported

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"

PROFILE_MODE=all      # all | core | list
WITH_LIST=()
STATIC_ONLY=0
KEEP=0
CI_ENV_FILE=""

usage() {
  cat <<'EOF'
Usage: ./scripts/ci-check.sh [options]

Runs static gates -> pick-ports -> up -> verify -> down -v on a random free port block above
10100, and fails if anything is left behind. Exit 0 means the whole chain passed and the
machine is clean.

Options:
  --static-only      the offline gates only (leak scan, decision matrix, compose pins).
                     No Docker daemon, no network, no containers. Run this before a push.
  --core-only        core profile only
  --with <profile>   bring up specific profiles instead of --all; repeatable
  --keep             on failure, leave the stack up for inspection (still cleaned on success)
  --env-file <path>  write the generated env file here and keep it (default: a temp file in
                     the repo, removed on exit)
  -h, --help         this text

Exit codes: 0 pass, 1 a step failed or something survived teardown, 2 bad usage.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --static-only) STATIC_ONLY=1; shift ;;
    --core-only)   PROFILE_MODE=core; shift ;;
    --with)        PROFILE_MODE=list; WITH_LIST+=(--with "${2:?--with needs a profile name}"); shift 2 ;;
    --keep)        KEEP=1; shift ;;
    --env-file)    CI_ENV_FILE="${2:?--env-file needs a path}"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *) err "unknown option: $1"; echo; usage; exit 2 ;;
  esac
done

PROFILE_ARGS=()
case "$PROFILE_MODE" in
  all)  PROFILE_ARGS=(--all) ;;
  core) PROFILE_ARGS=() ;;
  # `list` implies at least one --with, so WITH_LIST is non-empty here, but it is expanded
  # with the ${arr[@]+…} guard anyway: macOS bash 3.2 turns "${arr[@]}" on an empty array
  # into an `unbound variable` error under `set -u`.
  list) PROFILE_ARGS=(${WITH_LIST[@]+"${WITH_LIST[@]}"}) ;;
esac

FAILED=0
FAILED_STEP=""

step() {  # step <n> <label> <command...>
  local n="$1" label="$2"; shift 2
  local t0=$SECONDS
  echo
  log "step ${n}/5: ${label}"
  if "$@"; then
    ok "step ${n} passed in $(( SECONDS - t0 ))s"
    return 0
  fi
  err "step ${n} FAILED after $(( SECONDS - t0 ))s: ${label}"
  FAILED=1
  FAILED_STEP="${FAILED_STEP:-$label}"
  return 1
}

# ── step 1: the offline gates ────────────────────────────────────────────────
#
# Static and offline, so they run before anything is built or pulled and fail fast. None of
# them needs the Docker daemon, a network, a registry or a credential (`docker compose
# config` is client-side).
#
#   leak      no byte of the PRIVATE shieldedtech/midnight-intents-swaps source is committed
#             to this PUBLIC repository (spec FR-11). First, because it is the only failure
#             here that cannot be undone by fixing a file — a push has already published it.
#   decisions config/artifact-decisions.json is internally consistent and still makes the
#             choices it froze (`pinsDigest` makes an edited identity visible)
#   compose   the RENDERED compose configuration really asks for those bytes
#
# Each runs `--self-test`, so a check that stopped biting is reported as a failure rather
# than passing vacuously.
#
# shellcheck disable=SC2329  # invoked indirectly, as `step 1 <label> static_gates`
static_gates() {
  local rc=0
  "$REPO_ROOT/scripts/verify-no-private-source.sh" --self-test  >/dev/null || { rc=1; \
    "$REPO_ROOT/scripts/verify-no-private-source.sh" || true; }
  "$REPO_ROOT/scripts/verify-artifact-decisions.sh" --self-test >/dev/null && \
    ok "artifact decision matrix verified (with negative fixtures)" || rc=1
  "$REPO_ROOT/scripts/verify-compose-pins.sh" --self-test        >/dev/null && \
    ok "rendered compose pins verified (with negative fixtures)" || rc=1
  return "$rc"
}

step 1 "offline gates: private-source leak scan, decision matrix, rendered compose pins" \
  static_gates || true

if (( STATIC_ONLY )); then
  echo
  if (( FAILED )); then
    err "ci-check --static-only: FAILED at '${FAILED_STEP:-unknown}'"
    exit 1
  fi
  ok "ci-check --static-only: PASSED"
  exit 0
fi

require_docker

# This gate builds every shipped local image. Serialise Compose builds by default so the
# disposable clean-machine proof also works on small/shared Docker hosts without concurrent
# compiler/download layers multiplying the peak disk requirement.
export COMPOSE_PARALLEL_LIMIT="${COMPOSE_PARALLEL_LIMIT:-1}"
info "compose build parallelism ${COMPOSE_PARALLEL_LIMIT}"

# ── the disposable stack ─────────────────────────────────────────────────────
KEEP_ENV_FILE=1
if [[ -z "$CI_ENV_FILE" ]]; then
  # Inside the repo, not /tmp: ENV_FILE is also read by the compose --env-file flag, and a
  # repo-relative path keeps the whole run reproducible from the log. `.env.*` is gitignored.
  CI_ENV_FILE="$REPO_ROOT/.env.ci.$$"
  KEEP_ENV_FILE=0
fi

log "generating a collision-free stack definition"
if ! PROJECT_PREFIX=midnight-1-offers-ci "$REPO_ROOT/scripts/pick-ports.sh" > "$CI_ENV_FILE"; then
  err "pick-ports.sh could not find a free port block"
  rm -f "$CI_ENV_FILE"
  exit 1
fi
export ENV_FILE="$CI_ENV_FILE"
load_env
info "project ${COMPOSE_PROJECT_NAME}"
info "ports   node=${NODE_HOST_PORT} indexer=${INDEXER_HOST_PORT} proof=${PROOF_HOST_PORT}"
info "env     ${CI_ENV_FILE}"

# Generated by pick-ports.sh: unique to this run, so concurrent checkouts cannot overwrite or
# reuse our image tags. Teardown removes the tags after containers.
CI_IMAGE_TAGS=(
  "${POSTGRES_IMAGE:-}" "${CELESTIA_IMAGE:-}" "${KERNEL_IMAGE:-}" "${FRONTEND_IMAGE:-}"
  "${SOLVER_IMAGE:-}" "${RELAY_IMAGE:-}" "${INTENTS_UI_IMAGE:-}"
)

# ── teardown, asserted ───────────────────────────────────────────────────────
TORE_DOWN=0

# leak_count — prints "<containers> <volumes> <networks> <unlabelled-volumes>" for this
# project. The fourth number matters most: `docker volume create` (or a `docker run -v`)
# makes a volume with NO compose labels, so it is invisible to the first three counts.
#
# shellcheck disable=SC2329  # invoked from teardown(), which is itself invoked by a trap
leak_count() {
  local c v n u
  c=$(docker ps -aq --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" | wc -l | tr -d ' ')
  v=$(docker volume ls -q --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" | wc -l | tr -d ' ')
  n=$(docker network ls -q --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" | wc -l | tr -d ' ')
  u=$(docker volume ls -q | grep -cE "^${COMPOSE_PROJECT_NAME}[-_]" || true)
  printf '%s %s %s %s\n' "$c" "$v" "$n" "$u"
}

# shellcheck disable=SC2329  # invoked by the EXIT/INT/TERM traps installed below
teardown() {
  local rc=$?
  (( TORE_DOWN )) && return 0
  TORE_DOWN=1

  if (( KEEP && FAILED )); then
    echo
    warn "--keep: leaving project '${COMPOSE_PROJECT_NAME}' up for inspection"
    warn "clean it with: ENV_FILE=${CI_ENV_FILE} ./down.sh -v"
    return 0
  fi

  echo
  log "step 5/5: down -v (always runs, on every exit path)"
  if ! "$REPO_ROOT/down.sh" -v; then
    err "down.sh -v reported a problem"
    FAILED=1; FAILED_STEP="${FAILED_STEP:-down}"
  fi

  # Assert, rather than trust the exit code above.
  read -r C V N U <<<"$(leak_count)"
  local cache="$REPO_ROOT/.cache/${COMPOSE_PROJECT_NAME}"
  local cachestate="none"
  [[ -d "$cache" ]] && cachestate="PRESENT"
  info "after teardown: containers=${C} volumes=${V} networks=${N} unlabelled-volumes=${U} cache=${cachestate}"
  if (( C != 0 || V != 0 || N != 0 || U != 0 )) || [[ "$cachestate" != "none" ]]; then
    err "something survived the teardown — this stack is not disposable"
    (( C )) && docker ps -a --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}"
    (( V + U )) && docker volume ls | grep -E "${COMPOSE_PROJECT_NAME}" || true
    FAILED=1; FAILED_STEP="${FAILED_STEP:-teardown-leak}"
  else
    ok "nothing left behind"
  fi

  local image image_leaks=0
  for image in ${CI_IMAGE_TAGS[@]+"${CI_IMAGE_TAGS[@]}"}; do
    [[ -n "$image" ]] || continue
    docker image rm "$image" >/dev/null 2>&1 || true
    if docker image inspect "$image" >/dev/null 2>&1; then
      err "CI-specific image tag survived teardown: ${image}"
      image_leaks=$(( image_leaks + 1 ))
    fi
  done
  if (( image_leaks )); then
    FAILED=1; FAILED_STEP="${FAILED_STEP:-image-leak}"
  else
    ok "CI-specific image tags removed"
  fi

  if (( ! KEEP_ENV_FILE )); then
    rm -f "$CI_ENV_FILE"
    info "removed ${CI_ENV_FILE}"
  fi

  # Report the real outcome even when the trap fired from a signal.
  echo
  if (( FAILED )); then
    err "ci-check: FAILED at '${FAILED_STEP:-unknown}'"
    exit 1
  fi
  ok "ci-check: PASSED"
  exit "$rc"
}
trap teardown EXIT
trap 'echo; warn "interrupted"; FAILED=1; FAILED_STEP="interrupted"; exit 130' INT TERM

# ── the run ──────────────────────────────────────────────────────────────────
# Steps are chained so a failure short-circuits to the teardown rather than piling up
# secondary errors that hide the first one.
if (( ! FAILED )); then
  if step 2 "up --build ${PROFILE_ARGS[*]:-(core only)}" \
       "$REPO_ROOT/up.sh" --build ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}; then
    (( FAILED )) || step 3 "verify.sh" "$REPO_ROOT/verify.sh" || true
    (( FAILED )) || step 4 "verify exact baked source pins" \
      "$REPO_ROOT/scripts/verify-source-pins.sh" || true
  fi
fi

# The EXIT trap performs step 5 and decides the exit code.
exit 0
