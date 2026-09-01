#!/usr/bin/env bash
#
# Tear down the demo stack.
#
#   ./down.sh       stop and remove containers/networks, KEEP the chain + indexer volumes
#   ./down.sh -v    also wipe every volume of this compose project (full reset)
#
# The -v form wipes the node, indexer, Celestia, Postgres, deploy-share and batcher volumes
# TOGETHER, and that is not a convenience — it is a correctness requirement. They are one
# WIPE GROUP because each of them is keyed to a chain genesis:
#
#   * a fresh node genesis beside a surviving indexer database gives you an indexer serving
#     data for a chain that no longer exists;
#   * the offer-files contract address persisted by the deploy one-shot names a contract that
#     only exists on the old chain, so the kernel starts and its book is permanently empty;
#   * Celestia's bridge identifies its network by chain-id + genesis hash and refuses to
#     start against a mismatched data directory.
#
# The proof-data volume is the deliberate exception: it holds architecture-neutral SRS/ledger
# parameters that no chain identity touches, so plain `./down.sh` keeps it and the next
# bring-up does not re-download it. `-v` is a project-wide wipe and does remove it.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"

WIPE=0
PROFILES=""

usage() {
  cat <<'EOF'
Usage: ./down.sh [-v] [options]

Stops the demo stack. Without -v the chain and indexer data survive, so the next ./up.sh
resumes the same chain. With -v everything is wiped and the next ./up.sh starts a brand
new genesis.

Options:
  -v, --volumes   also remove all volumes of this compose project (FULL RESET)
  --all           accepted for symmetry with up.sh, but it changes nothing: down.sh ALWAYS
                  passes every fragment in compose/, so a profile brought up earlier can
                  never be orphaned by forgetting to name it here
  -h, --help      this text

Environment:
  ENV_FILE=<path> tear down the stack described by a different env file (i.e. a different
                  COMPOSE_PROJECT_NAME) — this is how one of two side-by-side stacks is
                  removed without touching the other.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--volumes) WIPE=1; shift ;;
    --all) shift ;;   # no-op: the loop below already includes every fragment
    -h|--help) usage; exit 0 ;;
    *) err "unknown option: $1"; echo; usage; exit 2 ;;
  esac
done

# Always tear down every profile whose fragment exists: `docker compose down` only removes
# what the given -f files declare, so a narrower file list would orphan the containers of a
# profile that was brought up earlier. This is why `--all` is redundant here — and why it is
# still accepted, rather than being an error someone has to discover mid-teardown.
while IFS= read -r p; do
  [[ " $PROFILES " == *" $p "* ]] || PROFILES="$PROFILES $p"
done < <(available_profiles)
export PROFILES

require_docker
load_env

if (( WIPE )); then
  log "tearing down project '${COMPOSE_PROJECT_NAME}' AND WIPING ALL VOLUMES"
else
  log "tearing down project '${COMPOSE_PROJECT_NAME}' (volumes kept)"
fi

if (( WIPE )); then
  dc down -v --remove-orphans
  # Host-directory caches are not compose volumes, so compose cannot remove them. They must
  # go with the chain: a cache keyed to a genesis that no longer exists makes the next run
  # fail in a way that looks nothing like "stale cache".
  CACHE_DIR="$REPO_ROOT/.cache/${COMPOSE_PROJECT_NAME}"
  if [[ -d "$CACHE_DIR" ]]; then
    rm -rf "$CACHE_DIR"
    info "removed host cache $CACHE_DIR"
  fi
else
  dc down --remove-orphans
fi

echo
log "remaining resources for project '${COMPOSE_PROJECT_NAME}'"
CONTAINERS=$(docker ps -aq --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" | wc -l | tr -d ' ')
VOLUMES=$(docker volume ls -q --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" | wc -l | tr -d ' ')
NETWORKS=$(docker network ls -q --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" | wc -l | tr -d ' ')
info "containers=${CONTAINERS}  volumes=${VOLUMES}  networks=${NETWORKS}"

if (( WIPE )); then
  if (( CONTAINERS == 0 && VOLUMES == 0 && NETWORKS == 0 )); then
    ok "nothing left behind"
  else
    warn "some resources survived the teardown — inspect with:"
    dim "docker ps -a --filter label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}"
    dim "docker volume ls --filter label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}"
    exit 1
  fi
else
  info "volumes kept — ./up.sh resumes the same chain; ./down.sh -v for a full reset"
fi
