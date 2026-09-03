# shellcheck shell=bash
#
# Shared helpers for the demo-stack scripts: env loading, compose invocation, and the
# health waits. Sourced, never executed.
#
# MACOS PORTABILITY IS A HARD REQUIREMENT HERE. macOS ships bash 3.2 (2007), and three
# classes of defect have already bitten the sibling repository badly enough to be written
# down rather than rediscovered:
#
#   1. `"${arr[@]}"` on an EMPTY array under `set -u` is an "unbound variable" ERROR in
#      bash 3.2 and zero words in bash 4.4+. Every Linux CI host hides it. Any array that
#      can be empty is expanded as `${arr[@]+"${arr[@]}"}`.
#   2. `docker logs … | grep -q …` under `pipefail` false-negatives: grep closes the pipe
#      on its first match, docker exits on SIGPIPE, and the pipeline reports failure. Match
#      without -q (or capture first), never `grep -q` in a pipefail pipeline.
#   3. `docker compose --env-file <missing>` is a hard error, and the clean-clone path has
#      no .env at all. `--env-file` is passed only when the file exists.

# REPO_ROOT is set by the caller before sourcing; derive it if not.
: "${REPO_ROOT:="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"}"

# ── output ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_DIM=$'\033[2m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_DIM=""
fi

log()  { printf '%s\n' "${C_BOLD}==>${C_RESET} $*"; }
info() { printf '%s\n' "    $*"; }
dim()  { printf '%s\n' "${C_DIM}    $*${C_RESET}"; }
ok()   { printf '%s\n' "    ${C_GREEN}OK${C_RESET}   $*"; }
warn() { printf '%s\n' "    ${C_YELLOW}WARN${C_RESET} $*"; }
err()  { printf '%s\n' "    ${C_RED}FAIL${C_RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

# ── immutable image references ───────────────────────────────────────────────
#
# require_digest_ref VAR… — each named variable must hold a COMPLETE immutable image
# reference, `<repository>@sha256:<64 hex>`.
#
# A tag is not an identity. `midnightntwrk/proof-server:8.1.0` can be repointed at different
# bytes at any moment without anything in this repository changing, which is exactly the
# failure config/artifact-decisions.json exists to prevent. So an override that supplies a
# tag is REJECTED rather than quietly accepted as a weaker pin: there is no digest→tag
# fallback anywhere in this stack.
#
# It REPORTS rather than exits, and `assert_image_pins` below is what makes it fatal. The
# split is deliberate: a bad pin must never be able to strand a running stack, so `down.sh`
# and the read-only verify scripts still work while every path that STARTS something fails
# hard. Teardown does not depend on image identity; starting does.
require_digest_ref() {
  local var val bad=0
  for var in "$@"; do
    val="${!var-}"
    if [[ ! "$val" =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]]; then
      err "${var} is not a complete immutable image reference"
      info "  got:      ${val:-<empty>}"
      info "  expected: <repository>@sha256:<64 hex>"
      bad=1
    fi
  done
  return "$bad"
}

# assert_image_pins — the fatal form, for anything that is about to start containers.
# load_env() only warns; up.sh calls this.
assert_image_pins() {
  require_digest_ref NODE_IMAGE INDEXER_IMAGE PROOF_IMAGE \
    || die "external runtime images are pinned by digest only — see config/artifact-decisions.json"
  return 0
}

# ── source pins ──────────────────────────────────────────────────────────────
#
# Everything this repository builds from source is fetched at a FULL 40-hex commit SHA.
# Never a branch, never a tag: Docker cannot see a branch move, so a branch-pinned build is
# both unreproducible and silently stale. A short SHA is also rejected — `git fetch` of an
# abbreviated sha fails outright, which is a confusing way to learn this.
require_commit_sha() {
  local var val bad=0
  for var in "$@"; do
    val="${!var-}"
    if [[ ! "$val" =~ ^[0-9a-f]{40}$ ]]; then
      err "${var} must be a full 40-character commit SHA, not a branch, tag or short sha"
      info "  got: ${val:-<empty>}"
      bad=1
    fi
  done
  return "$bad"
}

# ── env ──────────────────────────────────────────────────────────────────────
# Loads .env (or $ENV_FILE) into the environment, then applies the defaults so every
# variable the scripts read is always set. Values already exported win over the file,
# which lets a caller do `NODE_HOST_PORT=12345 ./up.sh` for a one-off.
load_env() {
  ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"

  if [[ -f "$ENV_FILE" ]]; then
    # Parsed rather than sourced: the file is plain KEY=value (docker compose's own
    # dialect), and sourcing it would let a stray backtick or $(…) in a value execute.
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue
      [[ "$line" != *=* ]] && continue
      key="${line%%=*}"; key="${key//[[:space:]]/}"
      val="${line#*=}"
      # Strip one layer of matching quotes, as compose does.
      [[ "$val" == \"*\" ]] && val="${val:1:${#val}-2}"
      [[ "$val" == \'*\' ]] && val="${val:1:${#val}-2}"
      [[ -n "${!key+x}" ]] && continue
      export "$key=$val"
    done < "$ENV_FILE"
  else
    warn "no $ENV_FILE — using built-in defaults (cp .env.example .env to customize)"
  fi

  # Its own project name, so a midnight-1-offers stack and a midnight-2-offers stack can be
  # up at the same time on one machine without sharing a single volume or container.
  : "${COMPOSE_PROJECT_NAME:=midnight-1-offers}"

  # ── RETIRED CONTROLS ───────────────────────────────────────────────────────
  # Say so out loud. A control that is silently ignored is worse than one that is gone: the
  # operator believes they changed the image and they did not.
  local retired
  for retired in NODE_TAG PROOF_TAG INDEXER_TAG TOOLKIT_TAG; do
    if [[ -n "${!retired-}" ]]; then
      warn "${retired} is RETIRED and IGNORED — set ${retired%_TAG}_IMAGE to a full <repo>@sha256:… reference instead"
    fi
  done
  # This repository has no AA, no EVM and no PGLite. Anything carried over from the 2.x
  # sibling or from the 1.x deploy prototype is not quietly dropped.
  for retired in AA_PROOF_IMAGE AA_CONSOLE_HOST_PORT AA_REF EVM_RPC_HOST_PORT EVM_WS_HOST_PORT \
                 UMBRA_REF PGLITE HOST_PGLITE_PORT SOLVER_SINK_HOST_PORT; do
    if [[ -n "${!retired-}" ]]; then
      warn "${retired} is IGNORED — this repository has no AA/EVM profile, no PGLite and no solver sink"
    fi
  done
  # There are THREE Compact toolchains here (kernel 0.30.0, zswap-da 0.31.0, shielded-night
  # 0.31.1), so one variable could never have configured them. Each is pinned where it is
  # enforced — a Dockerfile ARG in images/offerfiles-kernel, a literal in compose/frontend.yml
  # and one in compose/shielded-night.yml, both of which scripts/verify-compose-pins.sh binds
  # to their OWN matrix entry — and none of them reads the environment.
  if [[ -n "${COMPACT_VERSION-}" ]]; then
    warn "COMPACT_VERSION is IGNORED — kernel 0.30.0, zswap-da 0.31.0, shielded-night 0.31.1, all pinned in-build"
  fi

  # ── external runtime images: repository + IMMUTABLE DIGEST, never a tag ─────
  # All three are good official multiarch (linux/amd64 + linux/arm64) indexes, so the same
  # reference resolves natively on Intel and on Apple Silicon. Digests resolved 2026-09-01
  # and frozen in config/artifact-decisions.json; nothing here may drift from that file.
  : "${NODE_IMAGE:=docker.io/midnightntwrk/midnight-node@sha256:ede01da35e982b6a4b85461ad8492ae2753ef14246fba33c8039b782aa8e39fb}"
  : "${INDEXER_IMAGE:=docker.io/midnightntwrk/indexer-standalone@sha256:03afd079b00bcd229df29a24771439c5e7695c339cd89216d0763ce40731cc4b}"
  : "${PROOF_IMAGE:=docker.io/midnightntwrk/proof-server@sha256:801bbc0340e9e96f16735f77b523f23c7459e3359842f7c79c2c53f4e994d531}"
  # Reported here, made fatal by assert_image_pins() in whatever is about to start
  # containers — so a bad override cannot stop `./down.sh` from cleaning up.
  require_digest_ref NODE_IMAGE INDEXER_IMAGE PROOF_IMAGE \
    || warn "external runtime images must be digest-pinned; ./up.sh will refuse to start until this is fixed"

  # READABLE VERSION LABELS, display only. Nothing resolves an image from these; they exist
  # so logs can say "1.0.0" instead of a 64-character hash. Identity is the digest, only.
  : "${NODE_VERSION:=1.0.0}"
  : "${INDEXER_VERSION:=4.3.3}"
  : "${PROOF_VERSION:=8.1.0}"

  # ── source pins (full 40-hex commit SHAs; see config/artifact-decisions.json) ─
  # KERNEL_REF is `main` (re-pinned from `feat/cow-solver` in phase G, once kernel PR #48
  # merged the whole solver line into it — `git merge-base --is-ancestor` confirms the old pin
  # is an ancestor of this one, a pure fast-forward). SOLVER_REF below is UNCHANGED and stays a
  # strict ancestor of this ref too, so the kernel and the solver in this stack are still two
  # views of ONE tree. `main` also now carries the seeded reference-price service and the
  # batcher sponsorship gate (kernel PR #54/#56) — see .env.example.
  : "${KERNEL_REPO:=https://github.com/effectstream/zswap-offerfiles-kernel.git}"
  : "${KERNEL_REF:=61f055e83ae1ac4cb6e45031fb38c93c07f2d4d4}"
  : "${FRONTEND_REPO:=https://github.com/effectstream/effectstream.git}"
  : "${FRONTEND_REF:=f20a38cfccd4f2dec5c886e5c8bb321712d37924}"
  : "${SOLVER_REPO:=https://github.com/effectstream/zswap-offerfiles-kernel.git}"
  : "${SOLVER_REF:=c37bfa68cb944d883f52af7fa8ea533896a34654}"
  # The Shielded NIGHT dApp. A first-party public repository already on this stack's 1.x line
  # (ledger-v8 8.1.0 / midnight-js 4.1.1 / compact-runtime 0.16.0), so nothing here is
  # patched — see config/artifact-decisions.json -> sources[shielded-night].
  : "${SHIELDED_NIGHT_REPO:=https://github.com/effectstream/shielded-night.git}"
  : "${SHIELDED_NIGHT_REF:=f7fcefa7921bf2c3f634871f9ad3aa3a32251af0}"
  # The relay/intents-UI pin. There is deliberately no *_REPO for it: the source is private
  # and is never fetched by this repository. RELAY_SOURCE_DIR names the operator's own
  # clone, and assert_relay_source() below verifies that clone is at exactly this commit.
  : "${RELAY_REF:=061f4d3258e25b9f3a451b4b4358ed232349d96b}"
  : "${RELAY_SOURCE_DIR:=}"

  # ── warehouse-backed binaries (Celestia) ───────────────────────────────────
  : "${WAREHOUSE_REPO:=effectstream/binaries}"
  : "${WAREHOUSE_RELEASE:=0.3.120}"
  : "${CELESTIA_APP_VERSION:=6.4.10}"
  : "${CELESTIA_NODE_VERSION:=0.28.4}"

  # ── host ports ─────────────────────────────────────────────────────────────
  : "${BIND_ADDR:=127.0.0.1}"
  : "${NODE_HOST_PORT:=9944}"
  : "${INDEXER_HOST_PORT:=8088}"
  : "${PROOF_HOST_PORT:=6300}"
  : "${KERNEL_HOST_PORT:=9999}"
  : "${BATCHER_HOST_PORT:=3334}"
  : "${CELESTIA_HOST_PORT:=26658}"
  : "${FRONTEND_HOST_PORT:=10600}"
  : "${RELAY_HTTP_HOST_PORT:=13000}"
  : "${RELAY_WS_HOST_PORT:=19001}"
  : "${INTENTS_UI_HOST_PORT:=10700}"
  : "${SHIELDED_NIGHT_HOST_PORT:=10900}"

  # ── the shared PostgreSQL (Q7) ─────────────────────────────────────────────
  # The role/database the offer-files kernel authenticates as. Defaulted here as well as in
  # compose because verify.sh probes the REAL database with psql, not just the container's
  # health status — a healthy server with no `offerfiles` database in it is exactly the
  # failure the probe exists to catch. Postgres publishes no host port, so these are only
  # ever used through `docker compose exec`.
  : "${OFFERFILES_PG_USER:=offerfiles}"
  : "${OFFERFILES_PG_DB:=offerfiles}"

  # ── proof-data pre-warm ────────────────────────────────────────────────────
  # How long the one-shot may spend letting the proof server fetch and verify its startup
  # working set. Measured cold on a warm network: ~4s for 32.6 MB. The default is generous
  # because a cold cache on a slow link is the one case this budget exists for.
  : "${PROOF_WARM_TIMEOUT:=900}"

  # Indexer 4.3.3 serves an IDENTICAL GraphQL schema at /api/v3/graphql and /api/v4/graphql
  # (measured, not assumed). v3 is the 1.x-native path the ledger-v8 wallet SDK uses, so it
  # is the default; the variable exists so a consumer that needs v4 can be moved without a
  # code change, and verify.sh asserts BOTH paths answer.
  : "${INDEXER_API_PATH:=/api/v3/graphql}"

  # ── the shielded-night profile ─────────────────────────────────────────────
  # The DEPLOYER is genesis-2 and never genesis-1: on this stack genesis-1 is the faucet, the
  # offer-files deploy/mint wallet AND the kernel's own MIDNIGHT_WALLET_SEED, and two wallet
  # facades on one seed silently force each other's connection down (wallets/wallets.json).
  # shielded-night's own scripts default to genesis-1 on `undeployed`, so this is stated
  # explicitly here and the deploy entrypoint REFUSES that seed rather than trusting the env.
  : "${SHIELDED_NIGHT_WALLET_SEED:=0000000000000000000000000000000000000000000000000000000000000002}"
  # The verify round trip's DRIVER, and the sNight MAKER in the book chain. genesis-2 — the
  # SAME seed as the deployer, on purpose (project 00007 question Q6, owner decision D; spec
  # FR-011 amended): the deploy one-shot is `restart: "no"` and has exited before anything
  # reads contract.json, so the two facades never coexist. It used to default to `lace-test`,
  # which cost the operator a rule ("do not verify while Lace is connected"); that rule is
  # gone. See wallets/wallets.json and docs/KNOWN-LIMITATIONS.md.
  : "${SHIELDED_NIGHT_DRIVER_SEED:=0000000000000000000000000000000000000000000000000000000000000002}"
  # ── the book chain (./verify.sh's `book` subsection; needs the offerfiles profile) ────
  # How much NIGHT is wrapped, and the offer the wrapped sNight is then posted as. The taker
  # receives the sNight as ONE coin worth exactly SNIGHT_BOOK_AMOUNT, which is what lets the
  # unwrap step burn it whole (convertToUnshielded consumes one coin, never part of one).
  : "${SNIGHT_BOOK_AMOUNT:=1000000}"
  : "${SNIGHT_BOOK_WANT_AMOUNT:=750000}"
  # Which minted demo colour the sNight offer asks for. `shieldedA` is DEVA, `shieldedB` DEVB;
  # both are minted by the offerfiles deploy one-shot and named by its token-names one-shot.
  : "${SNIGHT_BOOK_WANT_KEY:=shieldedA}"
  # The taker, and the wallet that funds it. e2e-taker starts empty at genesis (measured), so
  # the chain provisions it from the faucet wallet — which is also the wallet the demo colours
  # were minted to, and therefore the only one that can hand it the token the offer demands.
  : "${SNIGHT_BOOK_TAKER_SEED:=${TAKER_SEED:-0000000000000000000000000000000000000000000000000000000000000032}}"
  : "${SNIGHT_BOOK_FUNDER_SEED:=${MIDNIGHT_GENESIS_SEED:-0000000000000000000000000000000000000000000000000000000000000001}}"
  : "${SHIELDED_NIGHT_NAME:=Shielded Night}"
  : "${SHIELDED_NIGHT_SYMBOL:=sNight}"
  : "${SHIELDED_NIGHT_DECIMALS:=6}"
  # Locking dissolves the contract's maintenance committee — a ONE-WAY door meant for hosted
  # releases. A throwaway devnet contract gains nothing from it, so the default is off; the
  # knob exists because the upstream repository's own release path uses it (spec FR-016).
  : "${SHIELDED_NIGHT_LOCK:=false}"
  # How long the web container waits for the deploy one-shot's contract.json before giving up.
  # A deploy proves and submits a real transaction on a cold chain; 600s is the same order as
  # KERNEL_WAIT_TIMEOUT and covers a loaded host.
  : "${SHIELDED_NIGHT_WAIT_TIMEOUT:=600}"

  # ── wait timeouts (seconds) ────────────────────────────────────────────────
  : "${NODE_WAIT_TIMEOUT:=180}"
  : "${INDEXER_WAIT_TIMEOUT:=420}"
  : "${PROOF_WAIT_TIMEOUT:=120}"
  # Postgres' own healthcheck allows initdb three minutes before it starts consuming
  # retries (compiling pg_ivm and running initdb on a loaded host is not instant), so the
  # host-side wait has to be at least as patient or it gives up on a healthy bring-up.
  : "${POSTGRES_WAIT_TIMEOUT:=300}"
  : "${CELESTIA_WAIT_TIMEOUT:=300}"
  : "${KERNEL_WAIT_TIMEOUT:=600}"
  : "${FRONTEND_WAIT_TIMEOUT:=300}"
  : "${SOLVER_WAIT_TIMEOUT:=300}"
  : "${RELAY_WAIT_TIMEOUT:=300}"

  export COMPOSE_PROJECT_NAME \
         NODE_IMAGE INDEXER_IMAGE PROOF_IMAGE \
         NODE_VERSION INDEXER_VERSION PROOF_VERSION \
         KERNEL_REPO KERNEL_REF FRONTEND_REPO FRONTEND_REF \
         SHIELDED_NIGHT_REPO SHIELDED_NIGHT_REF \
         SHIELDED_NIGHT_WALLET_SEED SHIELDED_NIGHT_DRIVER_SEED \
         SNIGHT_BOOK_AMOUNT SNIGHT_BOOK_WANT_AMOUNT SNIGHT_BOOK_WANT_KEY \
         SNIGHT_BOOK_TAKER_SEED SNIGHT_BOOK_FUNDER_SEED \
         SHIELDED_NIGHT_NAME SHIELDED_NIGHT_SYMBOL SHIELDED_NIGHT_DECIMALS \
         SHIELDED_NIGHT_LOCK SHIELDED_NIGHT_WAIT_TIMEOUT \
         SOLVER_REPO SOLVER_REF RELAY_REF RELAY_SOURCE_DIR \
         WAREHOUSE_REPO WAREHOUSE_RELEASE CELESTIA_APP_VERSION CELESTIA_NODE_VERSION \
         BIND_ADDR NODE_HOST_PORT INDEXER_HOST_PORT PROOF_HOST_PORT \
         KERNEL_HOST_PORT BATCHER_HOST_PORT CELESTIA_HOST_PORT FRONTEND_HOST_PORT \
         RELAY_HTTP_HOST_PORT RELAY_WS_HOST_PORT INTENTS_UI_HOST_PORT \
         SHIELDED_NIGHT_HOST_PORT \
         INDEXER_API_PATH OFFERFILES_PG_USER OFFERFILES_PG_DB PROOF_WARM_TIMEOUT \
         NODE_WAIT_TIMEOUT INDEXER_WAIT_TIMEOUT PROOF_WAIT_TIMEOUT POSTGRES_WAIT_TIMEOUT \
         CELESTIA_WAIT_TIMEOUT KERNEL_WAIT_TIMEOUT FRONTEND_WAIT_TIMEOUT \
         SOLVER_WAIT_TIMEOUT RELAY_WAIT_TIMEOUT

  # A host address the scripts can actually connect to. BIND_ADDR may be 0.0.0.0, which
  # is a valid bind target but not a valid connect target.
  HOST_ADDR="$BIND_ADDR"
  [[ "$HOST_ADDR" == "0.0.0.0" || -z "$HOST_ADDR" ]] && HOST_ADDR="127.0.0.1"
  export HOST_ADDR

  NODE_RPC_URL="http://${HOST_ADDR}:${NODE_HOST_PORT}"
  INDEXER_GQL_URL="http://${HOST_ADDR}:${INDEXER_HOST_PORT}${INDEXER_API_PATH}"
  KERNEL_URL="http://${HOST_ADDR}:${KERNEL_HOST_PORT}"
  BATCHER_URL="http://${HOST_ADDR}:${BATCHER_HOST_PORT}"
  RELAY_URL="http://${HOST_ADDR}:${RELAY_HTTP_HOST_PORT}"
  SHIELDED_NIGHT_URL="http://${HOST_ADDR}:${SHIELDED_NIGHT_HOST_PORT}"
  export NODE_RPC_URL INDEXER_GQL_URL KERNEL_URL BATCHER_URL RELAY_URL SHIELDED_NIGHT_URL
}

# ── the PRIVATE relay source (spec FR-11, plan Q4) ───────────────────────────
#
# The relay and the intents UI are built from `shieldedtech/midnight-intents-swaps`, which
# is private. This PUBLIC repository never fetches, vendors or mirrors it: the operator
# clones it themselves and points RELAY_SOURCE_DIR at their clone, which compose passes in
# as a named build context.
#
# RELAY_SOURCE_DIR names the WORKSPACE DIRECTORY INSIDE that clone — the build context —
# rather than the clone's root. That is not a style choice: this repository's own leak gate
# (scripts/lib/leak_scan.py) treats the private subtree's NAME as source content anywhere
# outside a comment, so `${RELAY_SOURCE_DIR}/<subtree>` cannot be written in a compose file
# or a script here at all. Composing that path is therefore the operator's job, and
# .env.example spells it out. Verification is unaffected: git resolves the enclosing
# repository from any subdirectory, so both checks below still cover the whole checkout.
#
# Fetching by SHA would have verified identity for free. A local directory does not, so it
# is verified HERE, before a single build starts: the clone must be a git checkout, sitting
# at exactly RELAY_REF, with no uncommitted changes. Otherwise the image silently becomes
# "whatever was on that operator's disk", which is the opposite of a pinned build.
#
# relay_source_required — true once compose/solver.yml actually declares services. While the
# fragment is still a placeholder there is nothing to build, so the guard says so instead of
# blocking `--all` on a private clone nothing needs yet. It arms itself when P4 lands.
relay_source_required() {
  [[ -n "$(profile_services solver 2>/dev/null)" ]]
}

assert_relay_source() {
  local dir="${RELAY_SOURCE_DIR:-}" head status

  if [[ -z "$dir" ]]; then
    err "the solver profile needs RELAY_SOURCE_DIR, and it is not set"
    info "The Midnight Intents relay and its browser UI are built from a PRIVATE repository."
    info "This public repository never carries their source, so you supply your own clone:"
    info ""
    info "    git clone git@github.com:shieldedtech/midnight-intents-swaps.git ./local/intents-swaps"
    info "    git -C ./local/intents-swaps checkout ${RELAY_REF}"
    info ""
    info "then point RELAY_SOURCE_DIR at the WORKSPACE DIRECTORY inside that clone — not at"
    info "the clone's root. .env.example gives the exact path; it is also recorded as"
    info "sources[intents-relay].subtree in config/artifact-decisions.json."
    info ""
    info "'local/' is gitignored for exactly this. Every other profile builds without it:"
    info "    ./up.sh --with offerfiles --with frontend"
    return 1
  fi

  if [[ ! -d "$dir" ]]; then
    err "RELAY_SOURCE_DIR does not exist: ${dir}"
    return 1
  fi
  # The build context, not the checkout root. Caught here rather than as a `COPY failed:
  # file not found` twenty layers into a build that has already downloaded a toolchain.
  if [[ ! -f "$dir/package.json" ]]; then
    err "RELAY_SOURCE_DIR has no package.json, so it is not the build context: ${dir}"
    info "It must name the WORKSPACE DIRECTORY inside your clone — the one holding"
    info "package.json, packages/ and infra/ — rather than the repository root."
    info "The exact path is in .env.example."
    return 1
  fi
  if ! head="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"; then
    err "RELAY_SOURCE_DIR is not a git checkout, so its identity cannot be verified: ${dir}"
    return 1
  fi
  if [[ "$head" != "$RELAY_REF" ]]; then
    err "RELAY_SOURCE_DIR is at the wrong commit"
    info "  clone:  ${head}"
    info "  pinned: ${RELAY_REF}   (RELAY_REF, config/artifact-decisions.json)"
    info "  fix:    git -C ${dir} fetch && git -C ${dir} checkout ${RELAY_REF}"
    return 1
  fi
  # A dirty tree makes the built image unreproducible and, worse, unreviewable: nobody can
  # say afterwards what went into it.
  status="$(git -C "$dir" status --porcelain 2>/dev/null)"
  if [[ -n "$status" ]]; then
    err "RELAY_SOURCE_DIR has uncommitted changes, so the image would not be reproducible"
    printf '%s\n' "$status" | sed 's/^/      /' >&2
    return 1
  fi
  ok "relay source ${dir} verified at ${RELAY_REF:0:12}… (clean tree)"
  return 0
}

# ── profiles ─────────────────────────────────────────────────────────────────
#
# A profile IS the basename of a compose fragment: `--with solver` adds compose/solver.yml.
# NO compose `profiles:` key is involved anywhere in this repository — `up.sh` never passes
# `--profile`, so a service carrying one would be declared and then never start, which is a
# uniquely quiet way to break a stack.
#
# There are exactly five: core, offerfiles, frontend, shielded-night, solver.

# KNOWN_FUTURE_PROFILES are profiles this stack reserves ports and documentation for but has
# not built yet. Empty: all four fragments exist. Keep the machinery for the next one.
# Both are read by up.sh, which shellcheck cannot see from inside this sourced library.
# shellcheck disable=SC2034
KNOWN_FUTURE_PROFILES=""
# shellcheck disable=SC2034
FUTURE_PROFILES_BLOCKER=""

# partial_profile_note <profile> — a profile that HAS a fragment (so `--with` accepts it and
# `--all` includes it) but does not yet contain every service the finished profile will.
# up.sh prints the note on every run.
#
# During the P0 scaffold that is ALL FOUR: the fragments are valid placeholders declaring no
# services. Saying so out loud, every time, is the difference between "a scaffold, on
# purpose" and "my stack is broken". Delete a profile's case when its phase lands its
# services; a note that outlives the gap it described is worse than none.
partial_profile_note() {
  case "$1" in
    *) return 1 ;;
  esac
}

# available_profiles — every profile that has a fragment today, one per line.
# `core` is excluded: it is unconditional, not opt-in.
available_profiles() {
  local f b
  for f in "$REPO_ROOT"/compose/*.yml; do
    [[ -e "$f" ]] || continue
    b="$(basename "$f" .yml)"
    [[ "$b" == "core" ]] && continue
    printf '%s\n' "$b"
  done
}

# pending_profiles — the known-but-unbuilt ones, i.e. KNOWN_FUTURE_PROFILES minus any that
# have since gained a fragment.
pending_profiles() {
  local p
  for p in $KNOWN_FUTURE_PROFILES; do
    [[ -f "$REPO_ROOT/compose/$p.yml" ]] || printf '%s\n' "$p"
  done
}

# ── which profiles are ALREADY UP ────────────────────────────────────────────
#
# `up.sh --with <profile>` is ADDITIVE: it must not stop a profile that is already running.
# To be additive, up.sh has to answer "which profiles have containers in this compose project
# right now", and that means mapping a container's compose SERVICE label back to the fragment
# that declares it.
#
# The mapping is asked of compose itself rather than parsed out of the YAML, because YAML
# parsed by hand is YAML parsed wrongly. But compose can only answer about a set of fragments
# it can RENDER, and a fragment does not render alone:
#
#     $ docker compose -f compose/core.yml -f compose/solver.yml config --services
#     service "solver-provision" declares unknown service "kernel" as additional contexts
#
# PROFILES ARE LAYERS, and that is the fix. `solver` builds on `offerfiles`, which builds on
# `core`, so a fragment is rendered together with every layer BENEATH it and the layers below
# are subtracted. Rendering `core + solver` alone — the obvious implementation, and the one
# this file shipped until P4 — fails, and a failed render is an EMPTY service list, which is
# indistinguishable from "this fragment is still a placeholder". That mistake was not
# theoretical: it silently disarmed relay_source_required() (so the private clone was never
# verified) and it made every solver container an unattributed ORPHAN, which
# `up.sh --with offerfiles` would then have removed mid-command.
#
# PROFILE_LAYER_ORDER is therefore load-bearing, not documentation: it must stay a valid
# dependency order. A fragment not named in it is treated as the topmost layer, which is the
# safe assumption for one this file has not been told about.
#
# `shielded-night` sits immediately above `core` because that is exactly what it depends on —
# node, indexer, proof server, and nothing else. Placing it at the END would make rendering it
# pull in `solver`, whose services take the kernel image as a named build context, and a
# failed render is silently indistinguishable from "this fragment declares no services".
PROFILE_LAYER_ORDER="core shielded-night offerfiles frontend solver"

# _layer_files <profile> [--below] — the `-f <fragment>` arguments for every layer up to and
# including <profile>, or strictly below it, one word per line.
_layer_files() {
  local target="$1" mode="${2:-}" p
  for p in $PROFILE_LAYER_ORDER; do
    if [[ "$p" == "$target" ]]; then
      [[ "$mode" == "--below" ]] && return 0
      [[ -f "$REPO_ROOT/compose/$p.yml" ]] && printf -- '-f\n%s\n' "$REPO_ROOT/compose/$p.yml"
      return 0
    fi
    [[ -f "$REPO_ROOT/compose/$p.yml" ]] && printf -- '-f\n%s\n' "$REPO_ROOT/compose/$p.yml"
  done
  # Not in PROFILE_LAYER_ORDER: every known layer is beneath it.
  [[ "$mode" == "--below" ]] && return 0
  [[ -f "$REPO_ROOT/compose/$target.yml" ]] && printf -- '-f\n%s\n' "$REPO_ROOT/compose/$target.yml"
  return 0
}

# _render_services <profile> [--below] — sorted service names for that layer stack. Cached,
# because up.sh asks for the same prefixes once per profile.
_render_services() {
  local target="$1" mode="${2:-}" key var files=() f out
  key="$(printf '%s%s' "$target" "$mode" | tr -c '[:alnum:]' '_')"
  var="_LAYER_SERVICES_${key}"
  if [[ -n "${!var-}" ]]; then
    printf '%s\n' "${!var}"
    return 0
  fi
  while IFS= read -r f; do files+=("$f"); done < <(_layer_files "$target" "$mode")
  if (( ${#files[@]} == 0 )); then
    eval "$var=' '"     # a space, not empty: the cache must be able to hold "nothing here"
    return 0
  fi
  out="$(docker compose ${files[@]+"${files[@]}"} config --services 2>/dev/null | sort)"
  eval "$var=\$out"
  printf '%s\n' "$out"
}

_CORE_SERVICES_CACHE=""
core_services() {
  if [[ -z "$_CORE_SERVICES_CACHE" ]]; then
    _CORE_SERVICES_CACHE="$(docker compose -f "$REPO_ROOT/compose/core.yml" config --services 2>/dev/null | sort)"
  fi
  printf '%s\n' "$_CORE_SERVICES_CACHE"
}

# profile_services <profile> — the services this fragment adds to the layers beneath it, one
# per line.
profile_services() {
  local p="$1" all base
  [[ -f "$REPO_ROOT/compose/$p.yml" ]] || return 0
  all="$(_render_services "$p")"
  [[ -n "${all//[[:space:]]/}" ]] || return 0
  base="$(_render_services "$p" --below)"
  comm -13 <(printf '%s\n' "$base" | grep -v '^[[:space:]]*$' | sort) \
           <(printf '%s\n' "$all"  | grep -v '^[[:space:]]*$' | sort)
}

# project_services — the compose service name of every container of this project, running or
# not. Stopped ones count: `up` would restart them, so a profile that is merely paused is
# still "up" as far as "do not silently remove it" is concerned.
project_services() {
  docker ps -a --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" \
    --format '{{.Label "com.docker.compose.service"}}' 2>/dev/null | sort -u
}

# running_profiles — every profile that has at least one container in this compose project.
#
# A container whose service is declared by NO fragment (a service deleted from a fragment
# since it was started) deliberately maps to nothing, so it stays an orphan and
# `--remove-orphans` still cleans it up. That is the one job `--remove-orphans` is there for.
running_profiles() {
  local svcs p s
  svcs="$(project_services)"
  [[ -n "${svcs//[[:space:]]/}" ]] || return 0
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    while IFS= read -r s; do
      [[ -n "$s" ]] || continue
      if printf '%s\n' "$svcs" | grep -Fxq -- "$s"; then
        printf '%s\n' "$p"
        break
      fi
    done < <(profile_services "$p")
  done < <(available_profiles)
}

# use_all_profiles — set PROFILES to every profile that has a fragment.
#
# For a script that only needs to reach ONE service. `dc` passes exactly the fragments named
# in PROFILES, and compose calls any container it has no definition for an ORPHAN — so a
# script that names only its own profile prints "Found orphan containers (…)" on every
# `run`/`exec` as soon as a second profile is up.
use_all_profiles() {
  local p
  PROFILES=""
  while IFS= read -r p; do PROFILES="$PROFILES $p"; done < <(available_profiles)
  export PROFILES
}

# ── compose ──────────────────────────────────────────────────────────────────
# The compose fragments for the requested profiles. `core` is unconditional.
# PROFILES is a space-separated list set by the caller (up.sh --with solver …).
compose_files() {
  local files=("-f" "$REPO_ROOT/compose/core.yml")
  local p
  for p in ${PROFILES:-}; do
    [[ -f "$REPO_ROOT/compose/$p.yml" ]] && files+=("-f" "$REPO_ROOT/compose/$p.yml")
  done
  printf '%s\n' "${files[@]}"
}

# ${arr[@]+"${arr[@]}"}, not "${arr[@]}", for any array that can be EMPTY here — see the
# bash 3.2 note at the top of this file. `env_args` is empty on the ordinary clean-clone
# path (no .env file), which is exactly where this used to abort.
dc() {
  local files=()
  while IFS= read -r f; do files+=("$f"); done < <(compose_files)
  local env_args=()
  [[ -f "${ENV_FILE:-}" ]] && env_args=(--env-file "$ENV_FILE")
  docker compose ${env_args[@]+"${env_args[@]}"} ${files[@]+"${files[@]}"} \
    -p "$COMPOSE_PROJECT_NAME" "$@"
}

require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
  docker compose version >/dev/null 2>&1 || die "docker compose v2 not available"
  docker info >/dev/null 2>&1 || die "docker daemon not reachable"
}

# ── waits ────────────────────────────────────────────────────────────────────

# wait_tcp <host> <port> <label> [timeout_secs]
# For services that cannot be probed from inside the container (the proof-server image has
# no curl/wget and its shell sits behind an unstable /nix/store path).
wait_tcp() {
  local host="$1" port="$2" label="$3" secs="${4:-120}"
  local deadline=$(( SECONDS + secs ))
  info "waiting for $label on $host:$port (up to ${secs}s)"
  while (( SECONDS < deadline )); do
    if command -v nc >/dev/null 2>&1; then
      nc -z "$host" "$port" >/dev/null 2>&1 && { ok "$label listening"; return 0; }
    else
      # bash's /dev/tcp needs no external binary.
      (exec 3<>"/dev/tcp/$host/$port") >/dev/null 2>&1 && { ok "$label listening"; return 0; }
    fi
    sleep 2
  done
  err "timeout waiting for $label on $host:$port"
  return 1
}

# wait_http <url> <label> [timeout_secs] [expect_substring]
# A generic readiness probe for the HTTP services this stack adds (kernel, batcher, relay,
# frontend). `expect_substring` makes it a real readiness check rather than "something
# answered": a 200 with the wrong body is a service that is up and useless.
wait_http() {
  local url="$1" label="$2" secs="${3:-120}" expect="${4:-}"
  local deadline=$(( SECONDS + secs )) body
  info "waiting for $label at $url (up to ${secs}s)"
  while (( SECONDS < deadline )); do
    if body="$(curl -fsS --max-time 5 "$url" 2>/dev/null)"; then
      if [[ -z "$expect" || "$body" == *"$expect"* ]]; then
        ok "$label answering"
        return 0
      fi
    fi
    sleep 2
  done
  local detail=""
  [[ -n "$expect" ]] && detail=" (answered, but never contained: ${expect})"
  err "timeout waiting for $label at ${url}${detail}"
  return 1
}

# wait_node_rpc <rpc_url> [timeout_secs]
# Block #1 exists only once the chain produces blocks, so this is readiness, not liveness.
wait_node_rpc() {
  local url="$1" secs="${2:-180}"
  local deadline=$(( SECONDS + secs ))
  info "waiting for node RPC at $url (up to ${secs}s)"
  while (( SECONDS < deadline )); do
    if curl -sf --max-time 5 -H 'Content-Type: application/json' \
         -d '{"id":1,"jsonrpc":"2.0","method":"chain_getBlockHash","params":[1]}' \
         "$url" 2>/dev/null | grep -q '"result":"0x'; then
      ok "node RPC answering (block #1 exists)"
      return 0
    fi
    sleep 2
  done
  err "timeout waiting for node RPC at $url"
  return 1
}

# wait_compose_healthy <service> [timeout_secs]
# Fast-fails the moment docker reports the container unhealthy rather than burning the whole
# timeout.
wait_compose_healthy() {
  local service="$1" secs="${2:-300}"
  local deadline=$(( SECONDS + secs ))
  info "waiting for compose service '$service' to report healthy (up to ${secs}s)"
  while (( SECONDS < deadline )); do
    local cid health state
    cid=$(docker ps -aq \
      --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" \
      --filter "label=com.docker.compose.service=$service" 2>/dev/null | head -1)
    if [[ -n "$cid" ]]; then
      state=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || echo "")
      health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo "")
      [[ "$health" == "healthy" ]] && { ok "$service healthy"; return 0; }
      if [[ "$health" == "unhealthy" ]]; then
        err "$service reported UNHEALTHY"
        return 1
      fi
      if [[ "$state" == "exited" || "$state" == "dead" ]]; then
        err "$service container $state before becoming healthy"
        return 1
      fi
    fi
    sleep 3
  done
  err "timeout waiting for $service to become healthy"
  return 1
}

# service_present <service> — does this compose project have a container for it, running or
# not? Every verify.sh section uses this to decide whether to run, so no flag is needed to
# do the right thing after `./up.sh --with <profile>`.
service_present() {
  [[ -n "$(docker ps -aq \
    --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" \
    --filter "label=com.docker.compose.service=$1" 2>/dev/null)" ]]
}

# ── chain / indexer queries ──────────────────────────────────────────────────

# node_best_height <rpc_url> — prints the best-chain height in decimal, or nothing.
node_best_height() {
  local hex
  hex=$(curl -sf --max-time 5 -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"chain_getHeader","params":[],"id":1}' "$1" 2>/dev/null \
    | grep -oE '"number"[[:space:]]*:[[:space:]]*"0x[0-9a-fA-F]+"' \
    | grep -oE '0x[0-9a-fA-F]+' | head -1 || true)
  [[ -n "$hex" ]] && echo "$((hex))"
}

# node_finalized_height <rpc_url> — prints the GRANDPA-finalized height in decimal.
node_finalized_height() {
  local url="$1" hash hex
  hash=$(curl -sf --max-time 5 -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"chain_getFinalizedHead","params":[],"id":1}' "$url" 2>/dev/null \
    | grep -oE '"result"[[:space:]]*:[[:space:]]*"0x[0-9a-fA-F]+"' \
    | grep -oE '0x[0-9a-fA-F]+' | head -1 || true)
  [[ -z "$hash" ]] && return 0
  hex=$(curl -sf --max-time 5 -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"chain_getHeader\",\"params\":[\"${hash}\"],\"id\":1}" "$url" 2>/dev/null \
    | grep -oE '"number"[[:space:]]*:[[:space:]]*"0x[0-9a-fA-F]+"' \
    | grep -oE '0x[0-9a-fA-F]+' | head -1 || true)
  [[ -n "$hex" ]] && echo "$((hex))"
}

# wait_finalized_height <rpc_url> <min_height> [timeout_secs]
#
# Waits until at least <min_height> blocks are FINALIZED, not merely produced. This is the
# gate anything that builds a transaction needs: the node answers RPC and has a best block
# long before finality moves off genesis, and in that window a wallet or toolkit refuses to
# work at all.
wait_finalized_height() {
  local url="$1" min="$2" secs="${3:-180}"
  local deadline=$(( SECONDS + secs ))
  local cur=""
  info "waiting for finalized height >= ${min} (up to ${secs}s)"
  while (( SECONDS < deadline )); do
    cur=$(node_finalized_height "$url")
    if [[ -n "$cur" ]] && (( cur >= min )); then
      ok "finalized height ${cur} >= ${min}"
      return 0
    fi
    sleep 2
  done
  err "finalized height did not reach ${min} within ${secs}s (last seen: ${cur:-none})"
  return 1
}

# wait_finalized_advances <rpc_url> [timeout_secs]
# Asserts finality is actually moving, not merely that a finalized head exists — a stalled
# GRANDPA still answers chain_getFinalizedHead with the same hash forever.
wait_finalized_advances() {
  local url="$1" secs="${2:-180}"
  local deadline=$(( SECONDS + secs ))
  local first="" cur=""
  info "waiting for finality to advance at $url (up to ${secs}s)"
  while (( SECONDS < deadline )); do
    cur=$(node_finalized_height "$url")
    if [[ -n "$cur" ]]; then
      if [[ -z "$first" ]]; then
        first="$cur"
        dim "finalized height starts at $first"
      elif (( cur > first )); then
        ok "finality advanced $first → $cur"
        return 0
      fi
    fi
    sleep 3
  done
  err "finality did not advance within ${secs}s (last seen: ${cur:-none})"
  return 1
}

# graphql <url> <query> — POSTs a GraphQL query, prints the raw response body.
graphql() {
  curl -sf --max-time 15 -H 'Content-Type: application/json' \
    -d "{\"query\":$(json_string "$2")}" "$1" 2>/dev/null
}

# json_string <text> — minimal JSON string encoder (no jq dependency).
json_string() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

# wait_indexer_graphql <gql_url> [timeout_secs]
# Real indexer readiness: a container healthcheck can only prove the process started, so the
# API is queried from the host.
wait_indexer_graphql() {
  local url="$1" secs="${2:-420}"
  local deadline=$(( SECONDS + secs ))
  info "waiting for indexer GraphQL at $url (up to ${secs}s)"
  while (( SECONDS < deadline )); do
    local body
    body=$(graphql "$url" '{ block { height hash } }' || true)
    if [[ -n "$body" && "$body" == *'"height"'* ]]; then
      ok "indexer GraphQL answering"
      return 0
    fi
    sleep 3
  done
  err "timeout waiting for indexer GraphQL at $url"
  return 1
}

# indexer_height <gql_url> — prints the indexer's latest known block height.
indexer_height() {
  graphql "$1" '{ block { height } }' \
    | grep -oE '"height"[[:space:]]*:[[:space:]]*[0-9]+' \
    | grep -oE '[0-9]+' | head -1
}
