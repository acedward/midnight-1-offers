#!/usr/bin/env bash
# Verify that the RENDERED compose configuration really asks for the artifacts this
# repository froze.
#
# config/artifact-decisions.json says what we promised to consume. It cannot tell whether
# Compose actually asks for those bytes — a default could be edited, a digest replaced by a
# tag, a source ref pointed at a branch, a `profiles:` key added that stops a service ever
# starting, or a port unbound from loopback, and every static check would still pass.
#
# So this renders each documented fragment combination with `docker compose config` — after
# every ${VAR:-default} resolves exactly the way the daemon will see it — and asserts the
# result.
#
#   ./scripts/verify-compose-pins.sh              # every documented fragment combination
#   ./scripts/verify-compose-pins.sh --self-test  # also prove the checks bite
#
# OFFLINE: `docker compose config` is client-side, so no daemon, network or registry is
# touched. It deliberately renders with an EMPTY env file, so what it checks is the
# COMMITTED DEFAULTS rather than whatever happens to be in somebody's .env.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"

MATRIX="$REPO_ROOT/config/artifact-decisions.json"
CHECKER="$REPO_ROOT/scripts/lib/compose_pins.py"

SELF_TEST=0
[[ "${1:-}" == "--self-test" ]] && SELF_TEST=1

command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v docker  >/dev/null 2>&1 || die "docker is required to render the compose configuration"
[[ -f "$MATRIX"  ]] || die "missing artifact decision matrix: $MATRIX"
[[ -f "$CHECKER" ]] || die "missing checker: $CHECKER"

# An empty env file, so committed defaults are what gets audited. /dev/null is not used
# because some compose versions reject a non-regular file here.
EMPTY_ENV="$(mktemp)"
RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "$EMPTY_ENV" "$RENDER_DIR"' EXIT

# The combinations a user can actually ask for. `core` is unconditional; every other
# fragment is additive on top of it. `solver` is always rendered together with `offerfiles`
# because it takes the kernel image as an additional build context. `shielded-night` is
# rendered BOTH alone on core (the profile depends on nothing else, and that has to stay
# true) and in the fullest stack, so a cross-fragment name collision cannot hide. `poster` is
# rendered on `offerfiles` alone (its only dependency — it needs neither relay nor solver) AND
# beside `solver`, because the two fragments declare the SAME `genesis-lock` volume and
# compose merging those two declarations is what the genesis-1 mutex rests on (00011 Q7).
COMBOS=(
  "core"
  "core offerfiles"
  "core frontend"
  "core shielded-night"
  "core offerfiles frontend"
  "core offerfiles shielded-night"
  "core offerfiles solver"
  "core offerfiles poster"
  "core offerfiles frontend solver"
  "core offerfiles poster solver"
  "core offerfiles frontend solver shielded-night poster"
)

FAILURES=0
RICHEST=""
RICHEST_N=-1

for combo in "${COMBOS[@]}"; do
  files=()
  for frag in $combo; do files+=(-f "$REPO_ROOT/compose/${frag}.yml"); done

  render="$RENDER_DIR/$(printf '%s' "$combo" | tr ' ' '-').json"
  # ${files[@]+…} guards the empty case: macOS bash 3.2 errors on "${files[@]}" under
  # `set -u` when the array has no elements. Same note as lib/common.sh's dc().
  if ! docker compose --env-file "$EMPTY_ENV" ${files[@]+"${files[@]}"} config --format json \
       >"$render" 2>"$render.err"; then
    err "compose could not render: ${combo}"
    sed 's/^/      /' "$render.err" >&2
    FAILURES=$(( FAILURES + 1 ))
    continue
  fi

  if python3 "$CHECKER" "$render" --matrix "$MATRIX" >/dev/null; then
    ok "compose pins verified: ${combo}"
  else
    err "compose pin violations: ${combo}"
    python3 "$CHECKER" "$render" --matrix "$MATRIX" 2>&1 | sed 's/^/      /' >&2 || true
    FAILURES=$(( FAILURES + 1 ))
  fi

  # The self-test mutates the richest rendering available, so every fixture has the best
  # chance of finding something real to break.
  n=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("services") or {}))' "$render")
  if (( n > RICHEST_N )); then RICHEST_N=$n; RICHEST="$render"; fi
done

if (( SELF_TEST )); then
  echo
  log "negative fixtures"
  if [[ -z "$RICHEST" ]]; then
    err "no rendering was produced, so the self-test has nothing to mutate"
    FAILURES=$(( FAILURES + 1 ))
  else
    # CAPTURE, THEN MATCH — never `… | grep …` for a result under `pipefail`. Same family of
    # defect as the `docker logs | grep -q` trap in scripts/lib/common.sh: the filter's own
    # exit status ends up standing in for the check's.
    #
    # And filter with `sed -nE`, not `sed -n '/a\|b/p'`: BSD sed (which is what macOS ships)
    # has no `\|` alternation in basic regular expressions, so the GNU form matches NOTHING
    # and quietly prints an empty report that still exits 0.
    SELF_RC=0
    SELF_OUT="$(python3 "$CHECKER" "$RICHEST" --matrix "$MATRIX" --self-test)" || SELF_RC=$?
    printf '%s\n' "$SELF_OUT" | sed -nE '/(self-test base|negative fixtures|ACCEPT|reject|N\/A)/p'
    if (( SELF_RC == 0 )); then
      ok "every negative fixture was rejected"
    else
      err "a known-bad compose rendering was ACCEPTED"
      FAILURES=$(( FAILURES + 1 ))
    fi
  fi
fi

if (( FAILURES == 0 )); then
  ok "rendered compose agrees with the frozen artifact decisions"
  exit 0
fi
err "${FAILURES} compose pin check(s) failed"
exit 1
