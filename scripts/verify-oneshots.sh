#!/usr/bin/env bash
#
# Assertions for every ONE-SHOT service in this stack — the `one-shots` section of ./verify.sh.
#
#   ./scripts/verify-oneshots.sh
#
# WHY THIS SECTION EXISTS (00020 phase G, the coverage audit).
#
# The eight compose fragments declare 32 services. Sixteen of them are long-running and every
# one is exercised by a profile section: the poster posts and a take settles, the relay quotes,
# the page is fetched, the feed writes prices. The other sixteen are ONE-SHOTS — they run once,
# do a job the rest of the stack depends on, and exit. Before this section, ten of them were
# asserted only INDIRECTLY (if the poster posts, its NIGHT provisioning must have worked) and
# five were asserted NOWHERE AT ALL:
#
#   proof-warm         populates the read-only /proof-data cache every prover mounts
#   poster-provision   funds the poster wallet with NIGHT from genesis (its DUST source)
#   poster-inventory   pre-mints POSTER_PREMINT_COUNT exact-size give coins for the poster
#   solver-provision   runs upstream's external-inventory check and writes the ladder
#   solver-inventory   mints the solver's two swap legs
#   maker-provision    funds the maker wallet with NIGHT from genesis
#   maker-inventory    mints the maker's give leg
#   maker-offer        posts the seeded offer the solver quotes against
#   issuer-deploy      deploys the six token contracts and publishes the registry
#   shielded-night-deploy  deploys the sNight contract the page and the book chain use
#
# An indirect assertion is not worthless, but it is not a coverage claim either: a one-shot
# that FAILS and is then made irrelevant by a resume path, a cached marker or a lucky retry
# leaves a green gate over a broken step. So this section makes the two claims that are true of
# every one-shot in the stack, for each one that is PRESENT:
#
#   1. it EXITED 0 — read off the container's own State.ExitCode, which is daemon-owned state
#      and cannot be forged by a log line;
#   2. its OBSERVABLE EFFECT is on the volume it was supposed to write — the provisioning
#      marker with its receipt, the ladder receipt, the registry, the contract address.
#
# `replicas: 0` one-shots (issuer-registry, issuer-registrar, issuer-fund, issuer-tokens-env,
# shielded-night-verify, shielded-night-token-name) are RUN by the profile sections that own
# them rather than observed here — except `issuer-tokens-env`, whose handoff nothing else
# asserted, so this section runs it and validates the projection it publishes.
#
# PROFILE-ADAPTIVE, never vacuous. Only services with a container in this compose project are
# asserted, and the section prints the count it checked. A stack brought up without `poster`
# has no poster one-shots to assert and says so; a stack that HAS them cannot pass this section
# without their exit codes and their effects.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) sed -n '2,48p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) err "unknown option: $1"; exit 2 ;;
  esac
done

require_docker
load_env
# Every fragment: `dc run` must resolve the services this section reads markers out of, and
# naming them all keeps compose from calling another profile's containers orphans.
use_all_profiles

FAILURES=0
fail() { err "$*"; FAILURES=$(( FAILURES + 1 )); }

CHECKED=0
ABSENT=""

# oneshot_cid <service> — the newest container id for that compose service, or nothing.
#
# Newest, not first: a `docker compose up` after a code change recreates a one-shot, leaving
# more than one container with the label, and the interesting one is the last to have run.
# `docker ps -aq` lists newest first.
#
# `oneoff=False` EXCLUDES `docker compose run` containers, and that matters here rather than
# being tidiness: this script itself runs `docker compose run --rm --entrypoint cat <service>`
# to read markers, and `verify-solver.sh` re-runs `maker-offer` the same way. Without the
# filter, a `run` container that had not finished being removed would become "the newest
# container for that service" and this section would assert the exit code of its own probe.
oneshot_cid() {
  docker ps -aq \
    --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" \
    --filter "label=com.docker.compose.service=$1" \
    --filter "label=com.docker.compose.oneoff=False" 2>/dev/null | head -1 || true
}

# assert_exited_zero <service> <what the job was>
#
# `State.Status` as well as the code, because a one-shot that is still RUNNING has ExitCode 0
# in docker's own inspect output — the field is only meaningful once the container is dead, and
# treating a live container's 0 as success is exactly the false pass this section exists to
# remove.
assert_exited_zero() {
  local svc="$1" what="$2" cid status code
  cid="$(oneshot_cid "$svc")"
  if [[ -z "$cid" ]]; then
    ABSENT="${ABSENT} ${svc}"
    return 0
  fi
  CHECKED=$(( CHECKED + 1 ))
  status="$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || true)"
  code="$(docker inspect -f '{{.State.ExitCode}}' "$cid" 2>/dev/null || true)"
  if [[ "$status" != "exited" ]]; then
    fail "${svc} is '${status:-unreadable}', not 'exited' — ${what} has not finished"
    return 0
  fi
  if [[ "$code" == "0" ]]; then
    ok "${svc} exited 0 — ${what}"
  else
    fail "${svc} exited ${code:-unreadable} — ${what} FAILED (docker compose logs ${svc})"
  fi
}

# read_from <service> <path> — cat a file out of a one-shot's own volumes.
#
# `dc run --rm --no-deps --entrypoint cat` rather than reading the exited container's
# filesystem: the volume is what the next consumer sees, and mounting it through the service's
# own definition is the only way to be sure this reads the same path the service wrote. The
# same idiom verify-solver.sh already uses for the maker-offer marker.
#
# `|| true` and `2>/dev/null`: a missing file must yield the empty string and a NAMED failure
# in the caller, never a pipefail exit from inside `$( )` (00011 C.8).
read_from() {
  dc run --rm --no-deps -T --entrypoint cat "$1" "$2" 2>/dev/null || true
}

# assert_marker <service> <path> <grep pattern> <label>
#
# The marker is not merely present, it carries the RECEIPT LINE the job prints. A zero-length
# marker (an interrupted write, a volume restored from another chain) satisfies `test -f` and
# proves nothing.
assert_marker() {
  local svc="$1" path="$2" pattern="$3" label="$4" body line
  [[ -n "$(oneshot_cid "$svc")" ]] || return 0
  body="$(read_from "$svc" "$path")"
  if [[ -z "$body" ]]; then
    fail "${svc}: ${path} is missing or empty — ${label} left no receipt on its volume"
    return 0
  fi
  line="$(printf '%s' "$body" | grep -m1 -E "$pattern" || true)"
  if [[ -n "$line" ]]; then
    ok "${svc}: ${label} — ${line}"
  else
    fail "${svc}: ${path} exists but carries no ${pattern} line — ${label} did not complete"
    dim "$(printf '%s' "$body" | head -3 | tr '\n' ' ')"
  fi
}

# ── core one-shots ───────────────────────────────────────────────────────────
echo
log "one-shots: core"
assert_exited_zero proof-warm "the /proof-data cache pre-warm every prover mounts read-only"
# The cache itself is asserted by verify.sh's core section (a file count inside proof-server,
# where the volume is mounted). Here the claim is the WRITER's, and the two together are what
# make "the prover has its keys" a measurement rather than an inference.

# ── the issuer ───────────────────────────────────────────────────────────────
if [[ -n "$(oneshot_cid issuer-deploy)" ]]; then
  echo
  log "one-shots: issuer"
  assert_exited_zero issuer-deploy "the six token contracts deployed and the registry published"
  # `issuer-tokens-env` is `replicas: 0` and nothing else asserted it. It projects the
  # validated registry into a shell-sourceable `tokens.env` that `offer-poster`,
  # `solver-provision` and `maker-offer` SOURCE at container start — so a wrong or missing
  # handoff is not cosmetic, it is the poster trading a colour nobody issued.
  TOKENS_ENV_RC=0
  dc run --rm --no-deps -T issuer-tokens-env >/dev/null 2>&1 || TOKENS_ENV_RC=$?
  if (( TOKENS_ENV_RC == 0 )); then
    ok "issuer-tokens-env exited 0 — the tokens.env handoff was (re)published from the registry"
  else
    fail "issuer-tokens-env exited ${TOKENS_ENV_RC} — the tokens.env handoff could not be published"
  fi
  TOKENS_ENV="$(read_from issuer-tokens-env /srv/issuer-tokens/tokens.env)"
  if [[ -z "$TOKENS_ENV" ]]; then
    fail "issuer-tokens-env: /srv/issuer-tokens/tokens.env is missing or empty"
  else
    # One `ISSUER_TOKEN_ID_<NAME>` per token, and every one a 64-hex colour. Counted with
    # `grep -c` under `|| true` and exercised on the empty state first (an absent file yields
    # 0, which the assertion names rather than passing).
    TE_IDS="$(printf '%s\n' "$TOKENS_ENV" | grep -cE '^ISSUER_TOKEN_ID_[A-Z]+=[0-9a-f]{64}$' || true)"
    TE_DECS="$(printf '%s\n' "$TOKENS_ENV" | grep -cE '^ISSUER_TOKEN_DECIMALS_[A-Z]+=[0-9]+$' || true)"
    TE_PRIV="$(printf '%s\n' "$TOKENS_ENV" | grep -cE '^ISSUER_TOKEN_PRIVACY_[A-Z]+=(shielded|unshielded)$' || true)"
    TE_SYM="$(printf '%s\n' "$TOKENS_ENV" | grep -cE '^ISSUER_TOKEN_SYMBOL_[A-Z]+=.' || true)"
    if [[ "${TE_IDS:-0}" == "6" && "${TE_DECS:-0}" == "6" \
       && "${TE_PRIV:-0}" == "6" && "${TE_SYM:-0}" == "6" ]]; then
      ok "tokens.env projects all six tokens with a 64-hex id, decimals, privacy and symbol each"
    else
      fail "tokens.env is incomplete: ids=${TE_IDS:-0} decimals=${TE_DECS:-0} privacy=${TE_PRIV:-0} symbols=${TE_SYM:-0} (want 6 of each)"
    fi
    # And the projection AGREES with the one registry reader in the image. A handoff that is
    # internally consistent but names a different chain's colours is the failure mode that
    # matters, and it is invisible without this cross-check.
    TE_MISMATCH=""
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      TE_NAME="$(printf '%s' "$line" | awk '{print $2}')"
      [[ -n "$TE_NAME" ]] || continue
      TE_WANT="$(issuer_token_id "$TE_NAME")"
      TE_GOT="$(printf '%s\n' "$TOKENS_ENV" | sed -n "s/^ISSUER_TOKEN_ID_${TE_NAME}=//p" | head -1 || true)"
      if [[ -z "$TE_WANT" || "$TE_GOT" != "$TE_WANT" ]]; then
        TE_MISMATCH="${TE_MISMATCH} ${TE_NAME}"
      fi
    done <<EOF
$(issuer_registry_lines)
EOF
    if [[ -z "$TE_MISMATCH" ]]; then
      ok "every tokens.env colour equals the registry's own colour for that name"
    else
      fail "tokens.env disagrees with the registry for:${TE_MISMATCH}"
    fi
  fi
fi

# ── shielded-night ───────────────────────────────────────────────────────────
if [[ -n "$(oneshot_cid shielded-night-deploy)" ]]; then
  echo
  log "one-shots: shielded-night"
  assert_exited_zero shielded-night-deploy "the sNight contract deployed on this chain"
  # `contract.json` on the deploy volume is the handoff the web container BLOCKS on, so its
  # address is this one-shot's whole observable effect. verify-shielded-night.sh reads the same
  # file through the WEB container (which mounts it read-only) and compares it with the served
  # /config.js; here it is read through the WRITER, which is what makes the two independent.
  SN_JSON="$(read_from shielded-night-deploy /srv/shielded-night/contract.json)"
  SN_ADDR="$(printf '%s' "$SN_JSON" \
    | grep -o '"address"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -1 | sed -e 's/.*:[[:space:]]*"//' -e 's/"$//' || true)"
  case "$SN_ADDR" in
    [0-9a-f][0-9a-f]*)
      ok "shielded-night-deploy published contract ${SN_ADDR:0:16}… in contract.json on its volume" ;;
    *)
      fail "shielded-night-deploy left no contract address in /srv/shielded-night/contract.json (got '${SN_ADDR}')" ;;
  esac
fi

# ── the solver's and the maker's provisioning lane ───────────────────────────
if [[ -n "$(oneshot_cid solver-provision)" ]]; then
  echo
  log "one-shots: solver provisioning"
  assert_exited_zero solver-inventory "the solver's two swap legs minted by the issuer"
  assert_marker solver-inventory /srv/solver-config/.inventory-provisioned \
    'ISSUER_FUND_RESULT ' "the solver inventory receipt"
  assert_exited_zero solver-provision "upstream's external-inventory check and the ladder"
  assert_exited_zero maker-provision "the maker wallet funded with NIGHT from genesis"
  assert_marker maker-provision /var/lib/maker-offer/.night-provisioned \
    'NIGHT_PROVISION_RESULT ' "the maker NIGHT receipt"
  assert_exited_zero maker-inventory "the maker's give leg minted by the issuer"
  assert_marker maker-inventory /var/lib/maker-offer/.inventory-provisioned \
    'ISSUER_FUND_RESULT ' "the maker inventory receipt"
  assert_exited_zero maker-offer "the seeded offer posted to the kernel book"
  # The marker's `give=/want=` line, NOT its `offerHash=`: the entrypoint writes the hash only
  # when it can resolve the 12-hex prefix its log printed back to a full hash, and says so when
  # it cannot — so an assertion on the hash would fail a correct tree. The hash's real
  # assertion is verify-solver.sh's "the seeded maker offer … is live", which reads the same
  # marker and re-seeds through this one-shot when the book has no live offer.
  assert_marker maker-offer /var/lib/maker-offer/.posted \
    'give=[0-9]+ want=[0-9]+' "the seeded offer's terms"
fi

# ── the poster's provisioning lane ───────────────────────────────────────────
if [[ -n "$(oneshot_cid poster-provision)" ]]; then
  echo
  log "one-shots: poster provisioning"
  assert_exited_zero poster-provision "the poster wallet funded with NIGHT from genesis"
  assert_marker poster-provision /var/lib/offer-poster/.night-provisioned \
    'NIGHT_PROVISION_RESULT ' "the poster NIGHT receipt"
  assert_exited_zero poster-inventory "the poster's pre-minted exact-size give coins"
  assert_marker poster-inventory /var/lib/offer-poster/.inventory-provisioned \
    'ISSUER_FUND_RESULT ' "the poster inventory receipt"
fi

# ── the summary, and the reason it names what it did NOT check ───────────────
echo
log "one-shots: coverage"
if (( CHECKED == 0 )); then
  fail "no one-shot container exists in project '${COMPOSE_PROJECT_NAME}' — nothing was asserted"
else
  ok "${CHECKED} one-shot(s) asserted: exited 0 AND left their receipt on their own volume"
fi
if [[ -n "$ABSENT" ]]; then
  info "not in this profile set, so not asserted:${ABSENT}"
fi

echo
if (( FAILURES == 0 )); then
  ok "one-shots: all assertions passed"
  exit 0
fi
err "one-shots: ${FAILURES} check(s) failed"
exit 1
