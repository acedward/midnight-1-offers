#!/usr/bin/env bash
# Verify that the images actually RUNNING were built from the exact configured artifacts,
# rather than from a stale shared :local image left behind by another checkout.
#
# Two kinds of assertion live here, and they answer different questions:
#
#   IMMUTABLE IMAGE REFERENCES — the containers that exist right now must have been created
#     from the digest-pinned references the matrix froze. verify-compose-pins.sh proves the
#     rendered CONFIGURATION asks for them; this proves the DAEMON was actually given them,
#     which is the claim a reviewer of a live stack cares about. A digest reference is
#     content-addressed, so equality here means the bytes are the pinned ones — no tag
#     lookup, no registry trust, and no "it was right when we rendered it".
#
#   SOURCE PINS — for everything built from source (kernel, batcher, solver, frontend,
#     relay, intents UI), the commit baked into the image at build time must equal the
#     configured full SHA. A `:local` tag says nothing about what is inside it.
#
# Every expectation is READ FROM config/artifact-decisions.json rather than duplicated here,
# so this script cannot drift from the matrix it is enforcing.
#
# Needs a running stack: it inspects containers and runs the built images. The offline gates
# are verify-artifact-decisions.sh and verify-compose-pins.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"
load_env

MATRIX="$REPO_ROOT/config/artifact-decisions.json"
PINS="$REPO_ROOT/scripts/lib/artifact_pins.py"

[[ -f "$MATRIX" ]] || die "missing artifact decision matrix: $MATRIX"
[[ -f "$PINS"   ]] || die "missing pin reader: $PINS"

FAILURES=0

# pin <matrix path> — one pinned value from the frozen artifact-decision matrix.
pin() {
  python3 "$PINS" "$MATRIX" "$1"
}

# assert_image_ref <label> <service> <expected full ref>
assert_image_ref() {
  local label="$1" service="$2" expected="$3" cid actual
  cid=$(docker ps -aq \
    --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" \
    --filter "label=com.docker.compose.service=${service}" 2>/dev/null | head -1)
  [[ -n "$cid" ]] || return 0   # service not part of the profiles that are up
  actual=$(docker inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null) || actual=""
  if [[ "$actual" == "$expected" ]]; then
    ok "${label} image ${expected#*@}"
    return 0
  fi
  err "${label}: container runs ${actual:-unreadable}, matrix pins ${expected}"
  FAILURES=$(( FAILURES + 1 ))
}

# assert_pin <label> <image> <path in image> <expected 40-hex commit>
assert_pin() {
  local label="$1" image="$2" path="$3" expected="$4" actual
  if [[ ! "$expected" =~ ^[0-9a-f]{40}$ ]]; then
    err "${label}: configured ref is not a full commit SHA (${expected})"
    FAILURES=$(( FAILURES + 1 ))
    return
  fi
  actual=$(docker run --rm --entrypoint cat "$image" "$path" 2>/dev/null | tr -d '\r\n') || actual=""
  if [[ "$actual" == "$expected" ]]; then
    ok "${label} source pin ${actual:0:12}…"
  else
    err "${label}: image ${image} baked ${actual:-unreadable}, expected ${expected}"
    FAILURES=$(( FAILURES + 1 ))
  fi
}

# ── external runtime images ──────────────────────────────────────────────────
assert_image_ref node "node" \
  "$(pin 'components[midnight-node].oci.repository')@$(pin 'components[midnight-node].oci.indexDigest')"
assert_image_ref indexer "indexer" \
  "$(pin 'components[indexer-standalone].oci.repository')@$(pin 'components[indexer-standalone].oci.indexDigest')"
assert_image_ref proof-server "proof-server" \
  "$(pin 'components[proof-server].oci.repository')@$(pin 'components[proof-server].oci.indexDigest')"

# ── source-built images ──────────────────────────────────────────────────────
# The env var wins if set (an operator may be testing a candidate ref), but the matrix is
# the default AND the thing a clean checkout is measured against.
KERNEL_EXPECTED="${KERNEL_REF:-$(pin 'sources[offerfiles-kernel].ref')}"
SOLVER_EXPECTED="${SOLVER_REF:-$(pin 'sources[cow-solver].ref')}"
FRONTEND_EXPECTED="${FRONTEND_REF:-$(pin 'sources[zswap-da-template].ref')}"
RELAY_EXPECTED="${RELAY_REF:-$(pin 'sources[intents-relay].ref')}"
SHIELDED_NIGHT_EXPECTED="${SHIELDED_NIGHT_REF:-$(pin 'sources[shielded-night].ref')}"

if service_present kernel; then
  assert_pin kernel "${KERNEL_IMAGE:-midnight-1-offers/offerfiles-kernel:local}" \
    /app/.kernel-commit "$KERNEL_EXPECTED"
fi
if service_present solver; then
  assert_pin solver "${SOLVER_IMAGE:-midnight-1-offers/cow-solver:local}" \
    /app/.solver-commit "$SOLVER_EXPECTED"
  # The solver image is overlaid onto the kernel image so it can reuse the already-compiled
  # Compact artifacts. That makes the kernel commit part of the SOLVER's identity too: a
  # solver built against a different kernel would rebuild maker bytes with mismatched
  # artifacts, which fails at settlement rather than at build.
  assert_pin solver-kernel-base "${SOLVER_IMAGE:-midnight-1-offers/cow-solver:local}" \
    /app/.kernel-commit "$KERNEL_EXPECTED"
fi
if service_present frontend; then
  assert_pin zswap-da "${FRONTEND_IMAGE:-midnight-1-offers/zswap-da:local}" \
    /.zswap-da-commit "$FRONTEND_EXPECTED"
  # The commit alone does not prove WHICH BYTES of templates/zswap-da were extracted, so the
  # subtree hash is asserted separately.
  SUBTREE_EXPECTED="$(pin 'sources[zswap-da-template].subtreeSha')"
  assert_pin zswap-da-subtree "${FRONTEND_IMAGE:-midnight-1-offers/zswap-da:local}" \
    /.zswap-da-subtree "$SUBTREE_EXPECTED"
fi
# BOTH shielded-night runtime targets carry the commit, and both are asserted. They are two
# images from one build — the nginx page server and the bun deploy/verify one-shot — and only
# one of them is what a browser sees. An operator answering "which revision is this page?"
# from the deploy container's label would be answering about the wrong artifact.
if service_present shielded-night; then
  assert_pin shielded-night "${SHIELDED_NIGHT_IMAGE:-midnight-1-offers/shielded-night:local}" \
    /.shielded-night-commit "$SHIELDED_NIGHT_EXPECTED"
fi
if service_present shielded-night-deploy; then
  assert_pin shielded-night-deploy "${SHIELDED_NIGHT_DEPLOY_IMAGE:-midnight-1-offers/shielded-night-deploy:local}" \
    /.shielded-night-commit "$SHIELDED_NIGHT_EXPECTED"
fi
# The relay and intents UI are built from the operator's own clone of a PRIVATE repository.
# Nothing here reads that source: the build bakes the commit it was given, and this asserts
# the baked value equals the pin. That is the whole verification surface available for a
# source this repository deliberately cannot fetch.
if service_present relay; then
  assert_pin relay "${RELAY_IMAGE:-midnight-1-offers/relay:local}" \
    /app/.relay-commit "$RELAY_EXPECTED"
fi
if service_present intents-ui; then
  assert_pin intents-ui "${INTENTS_UI_IMAGE:-midnight-1-offers/intents-ui:local}" \
    /.intents-ui-commit "$RELAY_EXPECTED"
fi

if (( FAILURES == 0 )); then
  ok "source provenance and image identity assertions passed"
  exit 0
fi
err "${FAILURES} source provenance / image identity assertion(s) failed"
exit 1
