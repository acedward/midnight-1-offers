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

PROFILES — there are exactly eight, and a profile IS a compose fragment in compose/, named
after the file. No compose \`profiles:\` key is used anywhere in this repository.

  core           ALWAYS on. midnight-node ${NODE_VERSION}, indexer-standalone ${INDEXER_VERSION},
                 proof-server ${PROOF_VERSION}, and the shared PostgreSQL.
  offerfiles     Celestia DA devnet, the contract deploy one-shot, the offer-files kernel
                 (:${KERNEL_HOST_PORT}) and the batcher (:${BATCHER_HOST_PORT}).
  frontend       the zswap-da SPA (:${FRONTEND_HOST_PORT}). Its Faucet tab is a LINK to the
                 issuer's faucet site since effectstream #922; that URL is baked into the
                 image, so rebuild the profile after changing FAUCET_HOST_PORT.
  shielded-night the Shielded NIGHT dApp (:${SHIELDED_NIGHT_HOST_PORT}) — NIGHT <-> sNight, wrapped
                 1:1 by a contract this profile deploys ONCE per stack. Depends only on core.
  solver         the Midnight Intents relay (:${RELAY_HTTP_HOST_PORT} HTTP, :${RELAY_WS_HOST_PORT} WS), the COW solver
                 in execution mode with its read-only status listener, the solver MONITOR
                 (:${SOLVER_FRONTEND_HOST_PORT}) and the intents browser UI (:${INTENTS_UI_HOST_PORT}).
                 BUILDS FROM A PRIVATE CLONE YOU SUPPLY — see RELAY_SOURCE_DIR below.
  poster         the OFFER POSTER (health :${POSTER_HEALTH_HOST_PORT}) — one funded, dedicated wallet that mints a
                 faucet coin a minute and posts ONE sponsored, individually takeable offer
                 spending exactly that coin, so the book fills itself. Needs \`offerfiles\`;
                 needs neither the relay nor the solver.
  prices         the PRICE FEED — one CoinGecko \`simple/price\` call a day into \`asset_prices\`,
                 the USD reference behind GET /v1/prices, GET /v1/quote and the sponsorship
                 gate. No port, no volume. Needs \`offerfiles\`. WITHOUT \`COINGECKO_API_KEY\` in
                 .env it comes up and IDLES with a warning — the schema's seeded prices already
                 quote real ratios — and ./verify.sh reports its section SKIPPED, not passed.
  issuer         THIS STACK'S OWN TOKEN ISSUER, and the faucet site for it (:${FAUCET_HOST_PORT}).
                 It deploys the six mint-test-tokens v1 contracts ONCE per chain —
                 TWBTC (8 dec) TWETH (18) TWUSDC (6) TWUSDM (6) UTWUSDC (6, unshielded)
                 UTWBTC (8, unshielded) — publishes their registry, and serves the static site
                 that mints them through a connected browser wallet. Open it at
                 http://${HOST_ADDR}:${FAUCET_HOST_PORT}/?network=undeployed
                 Depends only on core. With \`offerfiles\` up too, the kernel's token registry
                 learns all six colours. Automation mints headlessly instead:
                   docker compose run --rm issuer-fund TWBTC 100000000 <recipient-seed>

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
  ./up.sh --with shielded-night # …and the Shielded NIGHT dApp (needs nothing but core)
  ./up.sh --with offerfiles --with poster   # …and a book that supplies itself
  ./up.sh --with offerfiles --with prices   # …and live reference prices (needs COINGECKO_API_KEY)
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

# ── PROFILE DEPENDENCIES, resolved before anything else looks at PROFILES ────
# `poster` and `solver` REQUIRE `issuer` since 00020 PR C (questions Q9.3). Kernel #69 removed
# every way this stack had of minting a swap token, so their inventory one-shots run the ISSUER
# image and their long-lived services read the token handoff that profile publishes. Compose
# says so structurally — `poster-inventory` and `solver-inventory` `depends_on: issuer-deploy`,
# so the fragment set REFUSES to render without it — and this turns that refusal into the
# obvious thing instead, exactly as `core` is always present without being asked for.
#
# SAID OUT LOUD, once per added profile. A profile that appears without being typed is a
# surprise unless the reason is printed with it.
PROFILE_REQUIRES_ISSUER="poster solver"
for p in $PROFILE_REQUIRES_ISSUER; do
  [[ " $PROFILES " == *" $p "* ]] || continue
  [[ " $PROFILES " == *" issuer "* ]] && break
  if [[ -f "$REPO_ROOT/compose/issuer.yml" ]]; then
    PROFILES="$PROFILES issuer"
    info "profile  ${p} needs \`issuer\` (its swap-token inventory is minted there) — adding it"
    break
  fi
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

# A RENDER FAILURE AND AN EMPTY RENDER ARE DIFFERENT THINGS, and conflating them cost real
# time: a `${…}` sequence inside a healthcheck script made compose refuse the whole file, and
# because the old form here discarded stderr, up.sh reported "this repository is at its P0
# scaffold" and exited 0 — a broken fragment presented as a design state. Compose's own error
# names the file and the line; it must be shown, not swallowed.
if ! RENDERED_SERVICES="$(dc config --services 2>&1)"; then
  echo
  err "docker compose could not render this profile set (core${PROFILES// /, }):"
  printf '%s\n' "$RENDERED_SERVICES" | sed 's/^/      /' >&2
  info "nothing was started."
  exit 1
fi
# While every fragment is still a placeholder there is nothing to start, and `docker compose
# up` on an empty service set is a no-op that reads as success. Say what actually happened.
if [[ -z "${RENDERED_SERVICES//[[:space:]]/}" ]]; then
  echo
  warn "no services are declared yet — this repository is at its P0 scaffold"
  info "the compose fragments are valid placeholders; services land in P1 (core), P2"
  info "(offerfiles), P3 (frontend), P4 (solver) and 00011 PR C (poster). Nothing was started."
  exit 0
fi

FAILED=0

# ── THE OFFER POSTER IS THE LAST THING THIS SCRIPT STARTS (00025) ────────────
#
# THE DEFECT THIS CLOSES (organizer issues/00023, root cause issues/00024). One
# `docker compose up -d` starts `offer-poster` the moment its own `depends_on` is satisfied —
# kernel healthy, `poster-provision` and `poster-inventory` complete. `issuer-registrar`, the
# `deploy: { replicas: 0 }` one-shot that binds each of this stack's colours to its name, its
# decimals AND ITS `asset_id`, is run BY HAND further down this file, after the faucet is
# healthy. On this host that left a ~2-MINUTE WINDOW in which the poster was ticking against a
# kernel that did not know its colours, and the kernel's `GET /v1/quote` answers an unknown
# colour with a FABRICATED price of $1 per BASE UNIT (`source: "demo-fallback"`,
# `market_rate: 1`) — and still reports `sponsored: true`, because that flag is computed
# arithmetically from the fabricated prices rather than by the batcher's own gate.
#
# The poster believed it and posted. Measured on the 00020 phase-G gate: ticks 1 and 2 offered
# 1000000 base units of TWBTC (8 dec, ~$790) for 975000 base units of TWETH (18 dec,
# ~$0.000000002) — ELEVEN ORDERS OF MAGNITUDE off — and tick 3, after the registrar had run,
# asked 307632984238905018 for the same give leg. Those offers are real and settleable, and the
# solver's ladder derivation PREFERS them because they are by far the cheapest fill available:
# the whole published TWETH → TWBTC ladder was one rung, and that rung was tick 2.
#
# THE FIX IS ORDERING, and it lives here because it cannot live in compose. `depends_on` cannot
# name `issuer-registrar`: it is `replicas: 0` and cross-profile, and compose refuses a
# dependency — even `required: false` — on a service the selected fragments do not define. The
# information "is there an issuer, and has its registrar run?" exists in THIS FILE and nowhere
# else, exactly as it does for the three cross-profile steps further down.
#
# THE MECHANISM IS `--scale offer-poster=0`, MEASURED (not assumed) on docker compose v5.1.4:
#   * the service is still DECLARED and still RENDERS — `docker compose config` and
#     scripts/verify-compose-pins.sh see an ordinary service, and no fragment changes;
#   * `--remove-orphans` keeps working, and every other profile comes up as before;
#   * the poster's own one-shots STILL RUN EARLY and are still waited for: they only mint and
#     fund, they never quote. A pre-mint that FAILS still fails this `up` (measured: exit 1),
#     so the poster step below is never reached on a broken provisioning lane.
#
# AND IT IS CONDITIONAL, which is the part that is easy to get wrong: scaling a service to 0
# while its container is RUNNING stops and REMOVES it (measured). Passing the flag
# unconditionally would therefore bounce a healthy poster on every additive `./up.sh --with
# poster` — the opposite of the idempotence this has to preserve. So the flag is passed only
# when no `offer-poster` container is running for this project, and the other case is said out
# loud rather than silently skipped.
POSTER_HELD=0
UP_ARGS=()
if [[ " $PROFILES " == *" poster "* ]]; then
  # Only if the service really is in the rendered set. `--scale` on a name compose does not
  # know is a hard error, and RENDERED_SERVICES is the authority that was just computed above.
  case $'\n'"$RENDERED_SERVICES"$'\n' in
    *$'\n'offer-poster$'\n'*)
      if service_running offer-poster; then
        info "poster   offer-poster is ALREADY RUNNING — left alone (its colours were bound on"
        info "         the run that started it; nothing to re-order)"
      else
        POSTER_HELD=1
        UP_ARGS=(--scale offer-poster=0)
      fi
      ;;
  esac
fi

log "starting containers"
if (( POSTER_HELD )); then
  info "poster   offer-poster is held back from this \`up\` (--scale offer-poster=0) and started"
  info "         LAST, after issuer-registrar has bound this stack's colours — so its FIRST"
  info "         quote is a fed price. Its pre-mint one-shots still run now. See issues/00023."
fi
# ${arr[@]+"${arr[@]}"}, not "${arr[@]}": UP_ARGS is EMPTY on every bring-up without the poster
# and macOS bash 3.2 turns "${arr[@]}" on an empty array into an `unbound variable` error under
# `set -u` (the same rule as `env_args` in dc()).
if ! dc up -d --remove-orphans ${UP_ARGS[@]+"${UP_ARGS[@]}"}; then
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
  # The kernel's healthcheck asserts `synced`, not merely that the API answers, so this is
  # "the order book is current" rather than "the process started". It also implicitly covers
  # the offerfiles-deploy one-shot: compose will not start the kernel until that has exited 0.
  wait_compose_healthy kernel "$KERNEL_WAIT_TIMEOUT" || FAILED=1
fi
if (( ! FAILED )) && [[ " $PROFILES " == *" offerfiles "* ]] && service_present batcher; then
  wait_compose_healthy batcher "$KERNEL_WAIT_TIMEOUT" || FAILED=1
fi
if (( ! FAILED )) && [[ " $PROFILES " == *" frontend "* ]] && service_present frontend; then
  wait_compose_healthy frontend "$FRONTEND_WAIT_TIMEOUT" || FAILED=1
fi
# The shielded-night profile. `service_completed_successfully` on the deploy one-shot is what
# compose gates the web container on, and it is NOT enough on its own: it is equally satisfied
# by a one-shot that took the JOIN path against a volume from a previous chain. So the two
# things that actually matter are asserted here — the address really is on the volume, and the
# page really is serving it — and the address is named in the summary so an operator can see
# at a glance whether a `./down.sh -v` gave them a new contract.
if (( ! FAILED )) && [[ " $PROFILES " == *" shielded-night "* ]] && service_present shielded-night; then
  wait_compose_healthy shielded-night "$SHIELDED_NIGHT_WAIT_TIMEOUT" || FAILED=1
  if (( ! FAILED )); then
    # Read through the web container, which mounts the deploy volume read-only. `|| true`
    # keeps a failed exec reportable by the assertion below instead of killing the run.
    SHIELDED_NIGHT_CONTRACT="$(dc exec -T shielded-night \
      cat /srv/shielded-night/contract.json 2>/dev/null \
      | grep -o '"address"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -1 | sed -e 's/.*:[[:space:]]*"//' -e 's/"$//' || true)"
    if [[ -z "${SHIELDED_NIGHT_CONTRACT:-}" ]]; then
      err "the shielded-night-deploy one-shot published no contract address"
      FAILED=1
    fi
  fi
fi
# The issuer profile. compose gates the `faucet` container on `issuer-deploy`'s
# `service_completed_successfully`, so reaching healthy here means the whole issuer bring-up
# finished: the issuer wallet was funded from genesis and DUST-registered, six token contracts
# were deployed and verified on chain, and the registry was published. That is by far the
# longest wait in this stack — hence ISSUER_WAIT_TIMEOUT in minutes — and it is why the faucet's
# healthcheck asserts the registry's own `"status": "ready"` rather than merely that nginx binds.
if (( ! FAILED )) && [[ " $PROFILES " == *" issuer "* ]] && service_present faucet; then
  wait_compose_healthy faucet "$ISSUER_WAIT_TIMEOUT" || FAILED=1
  if (( ! FAILED )); then
    # Read the six through the faucet container, which mounts the registry volume read-only.
    # `service_completed_successfully` on the one-shot is NOT enough on its own: it is equally
    # satisfied by a one-shot that took the RESUME path against a registry from a previous
    # chain. What matters is that the file names six ACTIVE deployments, and that is asserted
    # here rather than assumed. `|| true` keeps a failed exec reportable by the assertion below
    # instead of killing the run.
    ISSUER_ACTIVE="$(dc exec -T faucet \
      grep -c '"status": "active"' /srv/issuer-registry/metadata.undeployed.json 2>/dev/null \
      | tr -cd '0-9' || true)"
    # `tr -cd '0-9'` first, so a non-numeric answer (an exec that failed, an empty file) becomes
    # the empty string and then 0 — never an arithmetic expression bash would evaluate as a
    # variable name. This is a cheap sanity check, not the gate: ./verify.sh's `issuer` section
    # validates the file against the schema AND the semantic validator.
    [[ -n "${ISSUER_ACTIVE}" ]] || ISSUER_ACTIVE=0
    if (( ISSUER_ACTIVE < 6 )); then
      err "the issuer registry names ${ISSUER_ACTIVE} active deployment(s), expected 6"
      info "  docker compose logs issuer-deploy"
      info "  docker compose run --rm --no-deps issuer-registry   # validate and dump it"
      FAILED=1
    else
      ok "the issuer registry names ${ISSUER_ACTIVE} active deployments"
    fi
  fi
fi
# ── the CROSS-PROFILE steps in this stack, and they live here on purpose ─────
# Four of them now, in this order: the sNight colour's name, the issuer's six colours, THE
# POSTER'S START (00025 — it must follow the registrar, see its own block), and the intents
# UI's labels and decimals. Every one of them is a fact that only THIS FILE knows, because it
# is the only place that knows which profiles were selected.
#
# When BOTH `offerfiles` and `shielded-night` are up, the kernel's dev token registry is told
# what the sNight colour is called. It cannot be a compose dependency in either direction:
# `shielded-night` must work with nothing but core (spec FR-002), and compose rejects a
# `depends_on` — even `required: false` — that names a service the selected fragments do not
# define. The information "is there a kernel?" exists HERE and nowhere else, so the one-shot is
# `deploy: { replicas: 0 }` and is invoked explicitly, after both profiles are healthy.
#
# NON-FATAL BY DESIGN. A colour without a friendly name is a cosmetic gap: the offer book, the
# page and every round trip work exactly the same. Failing a whole bring-up over a label would
# be the wrong trade, so this warns. `./verify.sh`'s book subsection is what asserts it.
#
# ── WHAT THIS BLOCK NO LONGER DOES (00015; organizer issues/00012) ───────────
# It used to answer an exit code 75 from the one-shot by running
# `DELETE FROM known_tokens WHERE upper(name) = 'SNIGHT'` against the stack's Postgres and
# re-running the one-shot. That worked around the kernel's seeded PREVIEW sNight colour by
# destroying the row. The one-shot now does the whole job itself, with the kernel's own
# prescribed statement (`UPDATE known_tokens … WHERE name = 'SNIGHT'`, versioned as
# images/shielded-night/sql/snight-registry-patch.sql) applied after the kernel is healthy,
# reports itself synced, and the chain is past block 1. There is no exit 75, no retry and no
# DELETE anywhere in this repository any more; a non-zero exit here is a real failure, printed
# by the one-shot itself and warned about below.
if (( ! FAILED )) \
   && [[ " $PROFILES " == *" shielded-night "* ]] && [[ " $PROFILES " == *" offerfiles "* ]] \
   && service_present shielded-night && service_present kernel; then
  log "registering the sNight colour with the offer-files token registry"
  SNIGHT_NAME_RC=0
  dc run --rm --no-deps -T shielded-night-token-name || SNIGHT_NAME_RC=$?
  if [ "$SNIGHT_NAME_RC" -ne 0 ]; then
    warn "could not name the sNight colour in the kernel registry (one-shot exit ${SNIGHT_NAME_RC}) — the book will show it as raw hex"
    info "(nothing else is affected; ./verify.sh --shielded-night reports it too. Re-run it alone with:"
    info " docker compose run --rm --no-deps shielded-night-token-name)"
  fi
fi
# The issuer's own half of the same pattern, and for the same reason. When BOTH `offerfiles` and
# `issuer` are up, the kernel's token registry is told what this stack's six colours are called.
# It cannot be a compose dependency in either direction: `issuer` must work with nothing but core
# (spec FR-002), and compose rejects a `depends_on` — even `required: false` — that names a
# service the selected fragments do not define. The information "is there a kernel?" exists HERE
# and nowhere else, so `issuer-registrar` is `deploy: { replicas: 0 }` and is invoked explicitly,
# after both profiles are healthy.
#
# FATAL, UNLIKE THE sNIGHT ONE — and the difference is not an inconsistency. A missing sNight
# LABEL is cosmetic: the offer book, the page and every round trip work identically. Here the
# kernel would be left holding the six canonical NAMES at the PUBLIC PREPROD colours its own
# seed shipped (kernel #69), i.e. six rows that confidently misidentify colours which do not
# exist on this chain — so every quote, every price and every sponsorship decision touching a
# TW*/UTW* name would be made against the wrong colour. That is worse than no label at all, so a
# non-zero exit here fails the bring-up and the one-shot's log says why.
if (( ! FAILED )) \
   && [[ " $PROFILES " == *" issuer "* ]] && [[ " $PROFILES " == *" offerfiles "* ]] \
   && service_present faucet && service_present kernel; then
  log "registering this stack's six issuer colours with the offer-files token registry"
  if ! dc run --rm --no-deps -T issuer-registrar; then
    err "could not register the issuer colours in the kernel registry"
    info "the kernel is left holding the six canonical NAMES at the Preprod colours its own seed"
    info "shipped — colours that do not exist on this chain. Re-run it alone with:"
    info "  docker compose run --rm --no-deps issuer-registrar"
    # SAID HERE TOO, because this is where the operator is looking. The poster step below is
    # guarded on FAILED and will name issues/00023 itself, but the causal link — "this is why
    # nothing is posting" — belongs beside the cause.
    (( POSTER_HELD )) && info "  offer-poster will NOT be started: on an unbound registry its first quote is fabricated (issues/00023)"
    FAILED=1
  fi
fi
# ── THE POSTER IS STARTED HERE, AND NOWHERE EARLIER (00025) ──────────────────
#
# Why it is held back at all is argued at the `--scale offer-poster=0` block above
# (issues/00023 and its root cause issues/00024). This is the other half: the poster is started
# here, and only after the registrar's effect has been CONFIRMED — not merely after its exit
# code.
#
# IMMEDIATELY AFTER THE REGISTRAR, and not at the bottom of the file, on purpose. The poster's
# own startup is minutes (wallet sync, DUST registration, the dust wait, the contract join), so
# starting it here lets it run CONCURRENTLY with the intents-UI bake below and with every
# remaining wait, exactly as it used to overlap with them when compose started it. The
# `wait_compose_healthy offer-poster` stays where it always was, further down — that is what
# makes this ordering cost the bring-up nothing but the colour poll.
#
# THE EXIT CODE IS NOT THE PROPERTY THE POSTER NEEDS. `issuer-registrar` exiting 0 says the
# `UPDATE known_tokens` and the `POST /v1/known-tokens` ran. What the poster's first quote
# depends on is the kernel being ABLE TO PRICE its two colours, and pricing resolves
# colour -> decimals + `asset_id` -> `asset_prices.price_usd / 10^decimals`. A colour with a
# NULL `asset_id` is the second fabrication in issues/00024: the kernel writes a deterministic
# colour-hash price with `source: "fallback"` for it. So the gate is the observable one —
# `GET /v1/known-tokens` carries a non-null `asset_id` for the give AND the want colour — and
# it is polled, bounded and NAMED on exhaustion.
#
# On a healthy stack this costs ONE poll: the registrar ran seconds ago and its own last act is
# to read the registry back.
if (( POSTER_HELD )); then
  echo
  if (( FAILED )); then
    # NOT started, and said as a failure line rather than a silent skip. `FAILED` is already 1
    # here — from the registrar, the faucet, the kernel or anything else above — and the whole
    # point of this project is that a poster started against an unbound registry posts real,
    # settleable, wildly mispriced offers.
    err "offer-poster was NOT started: this bring-up failed before the poster step"
    info "that is deliberate. On a kernel that does not yet know the poster's colours,"
    info "GET /v1/quote fabricates \$1 per BASE UNIT (market_rate=1) and still says"
    info "sponsored:true, and the poster posts real, settleable offers mispriced by ~11 orders"
    info "of magnitude that the solver's ladder then PREFERS. See the organizer's issues/00023"
    info "(the stack-side defect this ordering closes) and issues/00024 (the kernel half)."
    info "fix what failed above, then re-run ./up.sh — the poster is started by that run."
  else
    log "the poster starts LAST: waiting for the kernel to price its two colours"

    # ── the two colours, through the ONE registry reader in this repository ──
    # `issuer_registry_lines` is primed HERE, as a plain function call in this shell, so its
    # process-lifetime cache is set before the two `$( )` reads below inherit it. Called from
    # inside a command substitution instead, each read would be a SUBSHELL, the cache would
    # never survive, and every call would re-run `docker compose run --rm --no-deps -T
    # issuer-registry` — a container that INHERITS AND CONSUMES STDIN (measured in 00020 phase
    # G, where it ate five of six lines of a `while read` loop). One run, both colours.
    issuer_registry_lines >/dev/null 2>&1 || true

    # poster_colour <configured value> — the 64-hex colour for the poster's leg, or nothing.
    #
    # A raw 64-hex value passes through untouched and a NAME is resolved against the issuer's
    # registry: exactly what `entrypoint-offer-poster.sh` does with the same two variables, so
    # the gate describes the colours the poster will really trade. NEVER DEFAULTS — an
    # unresolvable name yields the empty string and the named failure below.
    poster_colour() {
      local value="${1:-}"
      case "$value" in
        ????????????????????????????????????????????????????????????????)
          case "$value" in
            *[!0-9a-f]*) : ;;
            *) printf '%s' "$value"; return 0 ;;
          esac ;;
      esac
      issuer_token_id "$value"
    }

    # poster_colour_priced <known-tokens body> <colour> — does that colour carry an asset_id?
    #
    # `tr '{' '\n'` splits the array into one row per line, the same idiom verify-kernel.sh
    # uses on this very endpoint (this host has no jq and these scripts take no dependency a
    # stock macOS box lacks). Whitespace-tolerant: the kernel's serialiser emits none today and
    # a check that silently stops matching if that changes is worse than one that reads the
    # value. `|| true` on both extractions — a body with no such row must yield the empty
    # string and a `return 1`, never a `pipefail` exit from inside `$( )` (00011 C.8).
    poster_colour_priced() {
      local body="${1:-}" colour="${2:-}" row hits
      [[ -n "$colour" ]] || return 1
      row="$(printf '%s' "$body" | tr '{' '\n' \
             | grep -E "\"token_color\"[[:space:]]*:[[:space:]]*\"${colour}\"" | head -1 || true)"
      [[ -n "$row" ]] || return 1
      # A non-null, non-empty asset_id. `"asset_id":null` and `"asset_id":""` both fail this.
      hits="$(printf '%s' "$row" | grep -cE '"asset_id"[[:space:]]*:[[:space:]]*"[^"]+"' || true)"
      [[ "${hits:-0}" != "0" ]]
    }

    POSTER_GIVE_COLOUR="$(poster_colour "${OFFER_POSTER_GIVE_TOKEN:-}" || true)"
    POSTER_WANT_COLOUR="$(poster_colour "${OFFER_POSTER_WANT_TOKEN:-}" || true)"
    if [[ -z "$POSTER_GIVE_COLOUR" || -z "$POSTER_WANT_COLOUR" ]]; then
      err "could not resolve the poster's two legs to colours on this chain"
      info "give ${OFFER_POSTER_GIVE_TOKEN:-unset} -> ${POSTER_GIVE_COLOUR:-nothing}"
      info "want ${OFFER_POSTER_WANT_TOKEN:-unset} -> ${POSTER_WANT_COLOUR:-nothing}"
      info "the \`poster\` profile requires \`issuer\` (this script adds it) and reads the six"
      info "colours through the one validating reader in the image. See what it reports with:"
      info "  docker compose run --rm --no-deps issuer-registry"
      info "offer-poster was NOT started (issues/00023)."
      FAILED=1
    else
      info "give ${OFFER_POSTER_GIVE_TOKEN} = ${POSTER_GIVE_COLOUR:0:16}…"
      info "want ${OFFER_POSTER_WANT_TOKEN} = ${POSTER_WANT_COLOUR:0:16}…"
      POSTER_COLOURS_START=$SECONDS
      POSTER_COLOURS_DEADLINE=$(( SECONDS + POSTER_COLOURS_WAIT_S ))
      POSTER_COLOURS_OK=0
      POSTER_KNOWN=""
      POSTER_COLOUR_TRIES=0
      while :; do
        POSTER_COLOUR_TRIES=$(( POSTER_COLOUR_TRIES + 1 ))
        POSTER_KNOWN="$(curl -fsS --max-time 10 "${KERNEL_URL}/v1/known-tokens" 2>/dev/null || true)"
        if [[ -n "$POSTER_KNOWN" ]] \
           && poster_colour_priced "$POSTER_KNOWN" "$POSTER_GIVE_COLOUR" \
           && poster_colour_priced "$POSTER_KNOWN" "$POSTER_WANT_COLOUR"; then
          POSTER_COLOURS_OK=1
          break
        fi
        (( SECONDS < POSTER_COLOURS_DEADLINE )) || break
        sleep "$POSTER_COLOURS_POLL_S"
      done
      POSTER_COLOURS_ELAPSED=$(( SECONDS - POSTER_COLOURS_START ))
      if (( POSTER_COLOURS_OK )); then
        ok "the kernel prices BOTH of the poster's colours (non-null asset_id) — ${POSTER_COLOURS_ELAPSED}s, ${POSTER_COLOUR_TRIES} poll(s)"

        # ── THE RECEIPT, WRITTEN BEFORE THE POSTER EXISTS ───────────────────
        #
        # `scripts/verify-poster.sh` proves the ordering by comparing this receipt's timestamp
        # with the poster container's own `State.StartedAt` (daemon-owned). It is written HERE,
        # in the one place that knows the colours were confirmed, and it is written ONLY on the
        # path that actually starts the poster — so an additive `./up.sh --with poster` that
        # leaves a running poster alone does NOT touch it, and the assertion keeps describing
        # the run that really did start this poster.
        #
        # WHY A RECEIPT ON THE VOLUME AND NOT THE REGISTRAR'S OWN CONTAINER. The registrar is a
        # `docker compose run --rm` one-shot: its container, and therefore its `FinishedAt`, is
        # gone the instant it exits. Keeping it (dropping `--rm`) was measured and rejected —
        # compose then calls it an ORPHAN of this `replicas: 0` service on every later
        # `docker compose up` and `run`, printing advice ("run with --remove-orphans") which, if
        # followed, deletes the very evidence the gate reads. A marker on the job's own volume is
        # the idiom this repository already uses for exactly this kind of claim; see
        # scripts/verify-oneshots.sh's header on why an effect on a volume is the assertable
        # half of a one-shot.
        #
        # The poster's own image and volume, so no new service and no new mount: `poster-state`
        # is where both provisioning markers already live, and `./down.sh -v` wipes it with the
        # chain. The container stamps the time itself with `date -u` (GNU coreutils is in this
        # image, and the format is the RFC3339-nano shape `docker inspect` emits).
        #
        # NON-FATAL. If the receipt cannot be written the poster still starts: the ordering has
        # already been established by the poll above, and refusing to trade over an unwritable
        # marker would be the wrong trade. `./verify.sh` reports the missing receipt itself.
        if dc run --rm --no-deps -T --entrypoint sh offer-poster -c \
             "printf 'POSTER_COLOURS_BOUND at=%s give=%s want=%s waited=%ss polls=%s\n' \
                \"\$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)\" \
                '${POSTER_GIVE_COLOUR}' '${POSTER_WANT_COLOUR}' \
                '${POSTER_COLOURS_ELAPSED}' '${POSTER_COLOUR_TRIES}' \
                > /var/lib/offer-poster/.colours-bound" >/dev/null 2>&1; then
          ok "receipt written to the poster's own volume: /var/lib/offer-poster/.colours-bound"
        else
          warn "could not write the colours-bound receipt on the poster-state volume"
          info "the poster is started anyway — the ordering was established by the poll above."
          info "./verify.sh's poster section reads that receipt to prove the ordering, so it"
          info "will report the gap rather than passing quietly."
        fi

        log "starting offer-poster — the last service in this bring-up"
        # `--no-deps`: every one of its declared dependencies (kernel healthy, both one-shots
        # completed) was satisfied by the `up` above, which would not have returned otherwise.
        # Without the flag compose re-evaluates the whole dependency graph and re-runs the
        # one-shots for a container that needs neither.
        if ! dc up -d --no-deps offer-poster; then
          err "could not start offer-poster after its colours were bound"
          info "  docker compose logs offer-poster"
          FAILED=1
        fi
      else
        err "the kernel still does not price the poster's colours after ${POSTER_COLOURS_ELAPSED}s (${POSTER_COLOUR_TRIES} poll(s), budget ${POSTER_COLOURS_WAIT_S}s)"
        info "give ${OFFER_POSTER_GIVE_TOKEN} ${POSTER_GIVE_COLOUR:0:16}… asset_id present: $(poster_colour_priced "$POSTER_KNOWN" "$POSTER_GIVE_COLOUR" && echo yes || echo no)"
        info "want ${OFFER_POSTER_WANT_TOKEN} ${POSTER_WANT_COLOUR:0:16}… asset_id present: $(poster_colour_priced "$POSTER_KNOWN" "$POSTER_WANT_COLOUR" && echo yes || echo no)"
        info "offer-poster was NOT started, on purpose: a colour the kernel cannot price is"
        info "quoted from a fabricated \$1 per BASE UNIT at market_rate=1 and STILL reported"
        info "sponsored:true, so the poster would post real, settleable offers mispriced by"
        info "~11 orders of magnitude. See issues/00023 and issues/00024."
        info "issuer-registrar writes that asset_id — read its log, then re-run ./up.sh:"
        info "  docker compose logs issuer-registrar"
        info "  docker compose run --rm --no-deps issuer-registrar"
        info "raise the budget with POSTER_COLOURS_WAIT_S=<seconds> if this host is slower."
        FAILED=1
      fi
    fi
  fi
fi
# ── the THIRD cross-profile step: the intents UI's labels and DECIMALS (00020 phase G) ──
#
# The browser UI takes a colour's label and its DECIMALS from a config block baked into
# `index.html` AT BUILD TIME (upstream's design, not this repository's choice — the relay's
# `GET /tokens` carries raw 64-hex colours and nothing else). This stack's colours derive from
# the contracts the `issuer` profile deploys, so they do not exist when the image is built. Up
# to 00020 phase F that left the operator a documented SECOND PASS to run by hand:
#
#   ./scripts/issuer-token-names.sh >> .env && ./up.sh --build
#
# WHY IT IS NO LONGER A MANUAL STEP. Until that pass runs, the page does not merely look ugly
# — it is WRONG ABOUT MONEY, and silently. With no entry for a colour the UI shows its last 8
# hex characters (cosmetic) but ALSO assumes SIX decimals: right for TWUSDC/TWUSDM/UTWUSDC,
# wrong for TWBTC and UTWBTC (8), and wrong by TWELVE ORDERS OF MAGNITUDE for TWETH (18).
# Nothing warns; the page renders a plausible number. That is the same "confidently wrong is
# worse than absent" argument the registrar block above makes about the kernel's colours, and
# it deserves the same answer: do it in the same pass.
#
# It has to be HERE and cannot be a build arg: the value is only knowable after
# `issuer-deploy` has published the registry, which is minutes after the build. So the image is
# rebuilt — one layer, the vite build — and the single container recreated.
#
# CONDITIONAL, so a second `./up.sh` on the same chain costs nothing but the check: the served
# page is asked whether it already carries the first colour, and the rebuild happens only when
# it does not.
#
# NON-FATAL, unlike the registrar. The difference is what is left behind on failure: a failed
# registrar leaves the KERNEL holding wrong colours, which every quote and every sponsorship
# decision then uses. A failed rebuild here leaves the UI as it was — showing hex tails and
# assuming six decimals — which is the pre-phase-G status quo, documented in
# docs/KNOWN-LIMITATIONS.md, and is a browser-side display problem rather than a wrong
# on-chain decision. `./verify.sh`'s solver section asserts the six DECIMALS out of the served
# bytes, so a stack that skipped this does not pass the gate quietly.
if (( ! FAILED )) \
   && [[ " $PROFILES " == *" issuer "* ]] && [[ " $PROFILES " == *" solver "* ]] \
   && service_present faucet && service_present intents-ui; then
  # `--value-only` prints just the comma-separated `NAME=<64-hex>:<decimals>:<label>` list; it
  # reads the registry through `issuer-registry`, this repository's ONE validating reader.
  # `|| true` so an unreadable registry yields the empty string and the warning below rather
  # than a `pipefail` exit (00011 C.8).
  UI_TOKEN_NAMES="$("$REPO_ROOT/scripts/issuer-token-names.sh" --value-only 2>/dev/null || true)"
  UI_TOKEN_NAMES="${UI_TOKEN_NAMES%%$'\n'*}"
  if [[ -z "${UI_TOKEN_NAMES//[[:space:]]/}" ]]; then
    warn "could not read this stack's token names from the issuer registry"
    info "the intents UI will show hex tails AND assume 6 decimals, which is wrong for TWBTC (8)"
    info "and wrong by twelve orders of magnitude for TWETH (18). See why with:"
    info "  ./scripts/issuer-token-names.sh --table"
  else
    # The first entry's colour, used only to decide whether a rebuild is needed. bash 3.2 has
    # no `${var##*(...)}` regex trim, so this is two ordinary expansions: take the first
    # comma-separated entry, then the field between the first `=` and the first `:`.
    UI_FIRST="${UI_TOKEN_NAMES%%,*}"
    UI_FIRST_COLOUR="${UI_FIRST#*=}"
    UI_FIRST_COLOUR="${UI_FIRST_COLOUR%%:*}"
    UI_PAGE="$(curl -fsS --max-time 10 \
      "http://${HOST_ADDR}:${INTENTS_UI_HOST_PORT}/" 2>/dev/null || true)"
    if [[ -n "$UI_FIRST_COLOUR" && "$UI_PAGE" == *"$UI_FIRST_COLOUR"* ]]; then
      ok "the intents UI already carries this chain's six token labels and decimals"
    else
      log "baking this chain's six token labels and decimals into the intents UI"
      info "(one image layer and one container; the colours only exist after issuer-deploy)"
      if INTENTS_UI_TOKEN_NAMES="$UI_TOKEN_NAMES" \
           dc up -d --build --no-deps intents-ui \
         && wait_compose_healthy intents-ui "$RELAY_WAIT_TIMEOUT"; then
        ok "the intents UI now names all six colours with their own decimals"
      else
        warn "could not rebuild the intents UI with this chain's token names"
        info "the page will show hex tails and assume 6 decimals (wrong for TWBTC and TWETH)."
        info "Do it by hand with:"
        info "  ./scripts/issuer-token-names.sh >> ${ENV_FILE##*/} && ./up.sh --build"
      fi
    fi
  fi
fi
# The poster's health server binds only AFTER wallet sync, DUST registration, the bounded dust
# wait and the contract join, which is why POSTER_WAIT_TIMEOUT is minutes and not seconds — and
# why compose gives its healthcheck a 15-minute start_period. Reaching healthy here means the
# poster is ALIVE, not that it has posted anything: /health answers 200 while it is still
# `starting` and while it is `degraded` (no dust yet), on purpose. Whether it actually mints
# and posts is ./verify.sh's poster section, which carries a budget for exactly that.
#
# `service_present` is still the guard and it is still the right one: on the held path the
# container was created by the step above, and on the already-running path it was there all
# along. If the step above failed, FAILED is 1 and this is skipped.
if (( ! FAILED )) && [[ " $PROFILES " == *" poster "* ]] && service_present offer-poster; then
  wait_compose_healthy offer-poster "$POSTER_WAIT_TIMEOUT" || FAILED=1
fi
# The price feed. It has NO healthcheck and cannot sensibly have one (compose/prices.yml says
# why: a loop that sleeps 24 h between cycles has no cheap in-container liveness signal, and
# the honest question — "did the last cycle succeed" — is a row in the database that the
# kernel serves, which is ./verify.sh's job). So this waits for the weaker but real property:
# the container is RUNNING and STAYS running, restart count unchanged. That is exactly the
# failure this profile can have — a configuration error under `restart: unless-stopped`, i.e.
# a crash loop `docker compose up -d` reports as success. A missing key is NOT that: the
# service idles by design and this wait passes, which is the intended behaviour on a clean
# host with no .env.
if (( ! FAILED )) && [[ " $PROFILES " == *" prices "* ]] && service_present price-feed; then
  wait_compose_running price-feed "${PRICES_SETTLE_S:-10}" "${PRICES_WAIT_TIMEOUT:-120}" || FAILED=1
fi
if (( ! FAILED )) && [[ " $PROFILES " == *" solver "* ]] && service_present relay; then
  wait_compose_healthy relay "$RELAY_WAIT_TIMEOUT" || FAILED=1
fi
if (( ! FAILED )) && [[ " $PROFILES " == *" solver "* ]] && service_present solver; then
  # Since 00015 the solver's healthcheck asks the SOLVER, not the relay: `GET /health` on its
  # own status listener, healthy iff `ready` is true. That flag is upstream's startup latch —
  # the book mirror's first sync, the kernel's backend projection and the wallet inventory have
  # all come good — so reaching healthy here means "the solver finished starting up", which is
  # a real and honest bring-up gate, and it still implicitly covers `solver-provision` (compose
  # will not start the solver until that one-shot has exited 0).
  #
  # It no longer means "the relay is advertising this solver's ladder". That is a claim about
  # three services and it is asserted where it belongs, in ./verify.sh's solver section — the
  # old healthcheck made it here and flapped 0/1 on every fail-closed empty ladder as a result
  # (issues/00013). `./verify.sh --solver` is what says the profile WORKS; this says it is UP.
  wait_compose_healthy solver "$SOLVER_WAIT_TIMEOUT" || FAILED=1
fi
if (( ! FAILED )) && [[ " $PROFILES " == *" solver "* ]] && service_present solver-frontend; then
  # The MONITOR, waited for AFTER the solver but not because it needs it: it depends on the
  # kernel alone and renders "SOLVER UNREACHABLE" perfectly happily. The order is only so a
  # green line here means "open this and the page is already telling you something".
  # Its /health is the SITE's own liveness and never follows the solver's state.
  wait_compose_healthy solver-frontend "$RELAY_WAIT_TIMEOUT" || FAILED=1
fi
if (( ! FAILED )) && [[ " $PROFILES " == *" solver "* ]] && service_present intents-ui; then
  wait_compose_healthy intents-ui "$RELAY_WAIT_TIMEOUT" || FAILED=1
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
# The SPA's Faucet link is the one value in this stack that is BAKED INTO AN IMAGE rather
# than written into /config.js at container start (effectstream #920 gives it no window.*
# override), so it is worth printing what this image was built with rather than what this
# .env says. `./verify.sh` asserts the two agree; a mismatch here means the frontend image
# predates the current port block and needs `./up.sh --build`.
service_present frontend     && info "SPA faucet link   ${FRONTEND_FAUCET_URL}   (baked at build time — rebuild after a port change)"
service_present shielded-night && info "Shielded NIGHT    http://${HOST_ADDR}:${SHIELDED_NIGHT_HOST_PORT}   contract ${SHIELDED_NIGHT_CONTRACT:-unknown}"
service_present relay        && info "intents relay     ${RELAY_URL}   (solver WS :${RELAY_WS_HOST_PORT})"
service_present solver-frontend && info "solver monitor    ${SOLVER_FRONTEND_URL}"
service_present intents-ui   && info "intents UI        http://${HOST_ADDR}:${INTENTS_UI_HOST_PORT}"
service_present offer-poster && info "offer poster      ${POSTER_URL}/health   (also /metrics /journal)"
# No URL of its own — it serves nothing. What it did is read through the kernel, and the
# one-off refresh is worth naming here because the loop's own next cycle is a day away.
service_present price-feed   && info "price feed        ${KERNEL_URL}/v1/prices?tokens=<colour>   (one refresh now: docker compose run --rm --no-deps price-feed --once)"
service_present faucet       && info "token faucet      ${FAUCET_URL}/?network=undeployed   (the ?network= is not optional)"
service_present faucet       && info "issuer tokens     docker compose run --rm --no-deps issuer-registry   (six ids + decimals)"
service_present faucet       && info "fund a wallet     docker compose run --rm issuer-fund TWBTC 100000000 <recipient-seed>"
echo
info "next: ./verify.sh    (assert the stack is usable, not merely running)"
info "      ./down.sh -v   (stop and wipe all chain/indexer/kernel state)"
