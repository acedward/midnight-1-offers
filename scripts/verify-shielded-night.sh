#!/usr/bin/env bash
#
# Assertions for the `shielded-night` profile — the `shielded-night` section of ./verify.sh.
#
#   ./scripts/verify-shielded-night.sh
#
# THE QUESTION THIS SCRIPT EXISTS TO ANSWER is not "does nginx serve a page". It is: IS THE
# THING THIS STACK IS SERVING THE CONTRACT THIS STACK DEPLOYED, and does that contract actually
# work? Those are five separate claims, and each is checked where it can fail:
#
#   serves      GET / answers an HTML document (nginx up, dist/ present).
#   config.js   GET /config.js is 200 and carries EXACTLY the address on the deploy volume —
#               not a stale one, not the baked-in preview one, not an empty string. It is
#               written at container start, so a 404 means the entrypoint never ran; and
#               index.html must load it BEFORE the module bundle or the override is dead.
#   zk assets   all 11 circuits' keys/<c>.prover, keys/<c>.verifier and zkir/<c>.bzkir answer
#               with non-empty BYTES, and a circuit that does not exist answers 404 — because
#               midnight-js's FetchZkConfigProvider only checks `response.ok`, so an SPA
#               fallback would hand the prover an HTML document as a proving key.
#   on-chain    the DEPLOYED contract's verifier keys are byte-identical to those served ones,
#               11 of 11, none missing and none extra (upstream's own verify-deployment.ts,
#               run inside the compose network against this stack's indexer).
#   round trip  a funded wallet (genesis-2, the deployer's own seed — that one-shot has long
#               exited) completes NIGHT -> sNight -> NIGHT both ways the contract offers —
#               atomic (one transaction each) and two-step — with EXACT balance assertions.
#   book        ONLY when the `offerfiles` profile is up: the reason this dApp belongs in an
#               OFFERS stack. Native NIGHT is wrapped into sNight, posted as a real MIP-0005
#               offer file against one of the stack's minted demo colours, found in the
#               kernel's book on the sNight colour, taken and settled by a second wallet, and
#               unwrapped by that wallet back into native NIGHT. Exact balances throughout.
#
# The last two run inside a container from the same image the contract was deployed from
# (`docker compose run --rm shielded-night-verify`), so this script needs no bun, no node and
# no dependency a clean macOS box does not already have: curl, grep and sed.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"

require_docker
load_env
# `dc` passes exactly the fragments named in PROFILES, and compose calls any container it has
# no definition for an ORPHAN — so naming only this profile would print "Found orphan
# containers (…)" on every exec as soon as a second profile is up. Nothing is started here.
use_all_profiles

BIND="${HOST_ADDR:-127.0.0.1}"
SNPORT="${SHIELDED_NIGHT_HOST_PORT:-10900}"
BASE="http://${BIND}:${SNPORT}"
ARTIFACTS="${BASE}/contract/compiled/shielded-night"

# The 11 circuits of the ShieldedNight contract. Written out rather than discovered, because
# "the page serves some keys" and "the page serves THIS contract" are different claims and only
# the second one is worth checking. The image asserts the same count on its own compiled
# output, from the other side.
CIRCUITS="convertToShielded convertToUnshielded decimals depositShielded depositUnshielded \
getBalance name symbol tokenColor withdrawShielded withdrawUnshielded"

# The colour kernel `main` @ c293ebd SEEDS into every fresh database for the name SNIGHT: the
# PREVIEW contract's (000-init.sql). It cannot exist on an `undeployed` devnet, where this stack
# deploys its own wrapper contract, so its presence anywhere in the registry means the
# shielded-night-token-name one-shot's patch did not run (00015; organizer issues/00012).
PREVIEW_SNIGHT_COLOR="793c29c94f72972bfbd861e8e84e55480ccc8e57a7b74067f35a5672c816f99c"

FAILURES=0
fail() { err "$*"; FAILURES=$(( FAILURES + 1 )); }

log "shielded-night: endpoints"
info "page      ${BASE}"
info "artifacts ${ARTIFACTS}/"

# ── the static surface ───────────────────────────────────────────────────────
echo
log "shielded-night: the page"

HTML="$(curl -fsS --max-time 10 "$BASE/" 2>/dev/null || true)"
if [[ "$HTML" == *"<html"* || "$HTML" == *"<!doctype"* || "$HTML" == *"<!DOCTYPE"* ]]; then
  ok "serves an HTML document on :${SNPORT}"
else
  fail "did not serve HTML on :${SNPORT}"
fi

CONFIG_JS=""
if CONFIG_JS="$(curl -fsS --max-time 10 "$BASE/config.js" 2>/dev/null)"; then
  # 200 IS NOT ENOUGH. Upstream ships a no-op `public/config.js` placeholder so that every
  # deployment serves a real script rather than a 404 the browser refuses to execute — and
  # that placeholder is in dist/. What proves this container learned an address is the marker
  # its ENTRYPOINT writes, so that is what is matched.
  case "$CONFIG_JS" in
    *'entrypoint-web.sh'*)
      ok "serves the GENERATED /config.js (written at container start, not the shipped placeholder)"
      ;;
    *)
      fail "/config.js is the upstream placeholder — the web entrypoint never wrote this stack's address"
      ;;
  esac
else
  CONFIG_JS=""
  fail "/config.js is missing — the web entrypoint did not run, or it never saw a contract"
fi

# WHAT MAKES config.js RUN FIRST IS THAT IT IS A *CLASSIC* SCRIPT, not where it sits in the
# document — and asserting document order here would be both wrong and red. Vite hoists the
# bundle's `<script type="module">` into <head> while the `<script src="/config.js">` tag stays
# in <body>, so the module tag comes FIRST in the served HTML. A module script is deferred by
# specification: it executes after the document is parsed, therefore after every classic script.
# A `type="module"` on the config tag is what would actually break this — the override would
# then be a second deferred script racing the bundle — so that is what is checked.
CFG_TAG="$(printf '%s' "$HTML" | grep -o '<script[^>]*src="/config\.js"[^>]*>' | head -1 || true)"
if [[ -z "$CFG_TAG" ]]; then
  fail "index.html does not reference /config.js — the runtime address override is dead"
elif [[ "$HTML" != *'<script type="module"'* ]]; then
  fail "index.html loads no module bundle — the served page is not the built SPA"
elif [[ "$CFG_TAG" == *'type="module"'* ]]; then
  fail "the /config.js tag is a MODULE script (${CFG_TAG}); it would be deferred alongside the bundle instead of running before it"
else
  ok "index.html loads /config.js as a classic script, so it runs before the deferred bundle"
fi

# ── the address, from the volume, compared EXACTLY ───────────────────────────
echo
log "shielded-night: the contract this stack deployed"

# Read the deploy volume through the web container, which mounts it read-only. `|| true` on
# both halves: an exec failure must be reported by the assertion below rather than killing the
# script through errexit, and a non-matching grep is a normal answer here.
CONTRACT_JSON="$(dc exec -T shielded-night cat /srv/shielded-night/contract.json 2>/dev/null || true)"
ADDRESS="$(printf '%s' "$CONTRACT_JSON" \
  | grep -o '"address"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | head -1 | sed -e 's/.*:[[:space:]]*"//' -e 's/"$//' || true)"

if [[ -z "$ADDRESS" ]]; then
  fail "no contract address on the shielded-night-deploy volume — the one-shot published nothing"
else
  ok "deploy volume carries contract ${ADDRESS:0:16}…"
  # EXACT, not a prefix: a stale /config.js from a previous chain would share no bytes with
  # this one, but a truncated comparison is how a "close enough" check passes on the wrong
  # contract. `case`, not `printf … | grep -Fq …`: a match makes grep close the pipe, the
  # producer dies of SIGPIPE and the pipeline reports failure under `pipefail`.
  case "$CONFIG_JS" in
    *"UNDEPLOYED_ADDRESS: \"${ADDRESS}\""*)
      ok "/config.js injects exactly this stack's address"
      ;;
    *)
      fail "/config.js does not carry the deployed address ${ADDRESS}"
      printf '%s\n' "$CONFIG_JS" | sed 's/^/      /' >&2
      ;;
  esac
  # The deploy record is this profile's identity document; the fields the docs promise must
  # actually be in it.
  for field in networkId symbol decimals deployerSeedRole commit; do
    case "$CONTRACT_JSON" in
      *"\"${field}\""*) ;;
      *) fail "contract.json carries no \"${field}\"" ;;
    esac
  done
  case "$CONTRACT_JSON" in
    *'"networkId": "undeployed"'*) ok "contract.json records networkId=undeployed" ;;
    *) fail "contract.json does not record networkId=undeployed" ;;
  esac
fi

# ── the ZK artifact lane ─────────────────────────────────────────────────────
#
# THREE FETCHES PER CIRCUIT, which is exactly what FetchZkConfigProvider makes. Each must be a
# 200 with a non-empty body that is NOT text/html: the provider checks only `response.ok`, so
# an SPA fallback would be accepted and the failure would surface deep inside proving.
echo
log "shielded-night: ZK artifacts for all 11 circuits"

ASSET_OK=0
ASSET_BAD=0
BODY="$(mktemp)"
HEADERS="$(mktemp)"
trap 'rm -f "$BODY" "$HEADERS"' EXIT

for circuit in $CIRCUITS; do
  for asset in "keys/${circuit}.prover" "keys/${circuit}.verifier" "zkir/${circuit}.bzkir"; do
    url="${ARTIFACTS}/${asset}"
    if ! curl -fsS -o "$BODY" -D "$HEADERS" --max-time 60 "$url" >/dev/null 2>&1; then
      fail "GET ${asset} did not answer 2xx — the browser prover cannot fetch this circuit"
      ASSET_BAD=$(( ASSET_BAD + 1 ))
      continue
    fi
    ctype="$(grep -i '^content-type:' "$HEADERS" | head -1 | tr -d '\r' | tr '[:upper:]' '[:lower:]' || true)"
    case "$ctype" in
      *text/html*)
        fail "GET ${asset} answered text/html — that is the SPA fallback, not a ZK artifact"
        ASSET_BAD=$(( ASSET_BAD + 1 ))
        continue
        ;;
    esac
    if [[ ! -s "$BODY" ]]; then
      fail "GET ${asset} answered an EMPTY body"
      ASSET_BAD=$(( ASSET_BAD + 1 ))
      continue
    fi
    ASSET_OK=$(( ASSET_OK + 1 ))
  done
done

if (( ASSET_BAD == 0 )); then
  ok "${ASSET_OK}/33 artifacts served as non-empty binary (11 circuits x prover/verifier/bzkir)"
else
  err "${ASSET_BAD} of $(( ASSET_OK + ASSET_BAD )) artifact fetches failed"
fi

# THE NEGATIVE CONTROL, and it is the whole point of `try_files … =404` in nginx.conf. Without
# it this URL answers 200 with the app shell and every check above would still pass while the
# prover was being handed HTML.
BOGUS_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
  "${ARTIFACTS}/keys/thisCircuitDoesNotExist.prover" 2>/dev/null || true)"
if [[ "$BOGUS_CODE" == "404" ]]; then
  ok "a missing artifact answers 404, not the SPA fallback"
else
  fail "a missing artifact answered HTTP ${BOGUS_CODE:-none}; it must be 404, never the app shell"
fi

# ── the on-chain verifier keys ───────────────────────────────────────────────
#
# `docker compose run --rm`, not an exec into a running container: the verify service exists
# precisely so this runs in a container with the pinned tree, its node_modules and the compiled
# keys, INSIDE the compose network, and then goes away. The service declares
# `deploy: { replicas: 0 }` so `up.sh` never starts it.
echo
log "shielded-night: on-chain verifier keys == served keys"
if dc run --rm -T shielded-night-verify keys; then
  ok "11/11 circuits verified on chain against the served keys"
else
  fail "the on-chain verifier keys do not match the served ones (see the output above)"
fi

# ── the round trip ───────────────────────────────────────────────────────────
#
# The UPSTREAM integration suite, run against THIS stack (MN_EXTERNAL_STACK=1) on the driver
# wallet. Both selected tests assert EXACT balances: wrapped == N, and final NIGHT == starting
# NIGHT.
#
# It is a REQUIRED check, not an optional one — a profile that serves a page for a contract
# nobody has ever transacted with is not verified. If the driver wallet cannot be funded the
# container fails and so does this section, loudly.
echo
log "shielded-night: NIGHT <-> sNight round trips (atomic and two-step)"
info "driver wallet is SHIELDED_NIGHT_DRIVER_SEED (genesis-2 by default — Q6/D)"
if dc run --rm -T shielded-night-verify roundtrip; then
  ok "both round trips completed with exact balance assertions"
else
  fail "a NIGHT <-> sNight round trip failed (see the output above)"
fi

# ── the BOOK CHAIN: NIGHT -> sNight -> an offer file on the kernel's order book ─
#
# THE WHOLE POINT OF PUTTING THIS dApp IN AN *OFFERS* STACK. Native NIGHT cannot be traded on
# the offer-files book — the book trades shielded tokens and NIGHT is unshielded. Wrapped, it
# can be. This subsection proves that end to end, on this stack, with exact balances:
#
#   1. wrap    N NIGHT -> N sNight on the maker wallet, against THIS stack's deployed contract
#   2. offer   a real MIP-0005 offer file GIVING that sNight and WANTING a minted demo colour,
#              posted through POST /v1/offers exactly as the repository's own maker-offer
#              one-shot posts its DEVA/DEVB offer (same script, same code path, same wallet
#              plumbing) — only the two colours and the seed differ
#   3. book    GET /v1/offers?token=<sNight colour>&direction=GIVING lists it, with the sNight
#              colour as its GIVING leg and both amounts exact
#   4. take    a second wallet balances that offer file and settles it on chain; the kernel
#              reports the offer `consumed`; the taker's sNight goes up by exactly the give
#              amount and its demanded token down by exactly the want amount
#   5. unwrap  the taker — which never wrapped anything and received its sNight from a
#              stranger's offer file — converts it back to native NIGHT, +N exactly
#
# IT RUNS IF AND ONLY IF THE `offerfiles` PROFILE IS UP. `--with shielded-night` alone is a
# complete, supported stack (spec FR-002) and there is no book on it; the absence is reported
# as a SKIP, never as a failure and never silently.
#
# EVERY STEP RUNS IN A CONTAINER of this stack's own images. No host bun, no host node: the
# wrap and unwrap use the shielded-night image (the pinned tree, its node_modules and the
# compiled keys), the offer and the take use the kernel image (the MIP-0005 codec and the
# wallet facade). This script only sequences them and owns the verdict.
#
# SHIELDED_NIGHT_SKIP_BOOK=1 skips this WHOLE subsection (phase G) — a proving-heavy ~10-15 min
# chain (five on-chain steps: wrap, post, list, take, unwrap), distinct from the two round
# trips above (~10 min, ALWAYS run — they are what actually prove the contract works). It
# exists for a gate under a hard time budget that still wants offerfiles+shielded-night wired
# together (compose renders, the cross-profile one-shot fires, the round trips pass) without
# paying for the book chain's own proving time. Not a silent default: it prints why it skipped.
echo
log "shielded-night: the book chain (NIGHT -> sNight -> an sNight offer file)"

if [[ "${SHIELDED_NIGHT_SKIP_BOOK:-}" == "true" || "${SHIELDED_NIGHT_SKIP_BOOK:-}" == "1" ]]; then
  info "SKIP (SHIELDED_NIGHT_SKIP_BOOK=${SHIELDED_NIGHT_SKIP_BOOK}) — the round trips above already proved the contract; the book chain itself was not run"
  echo
  if (( FAILURES == 0 )); then
    ok "shielded-night assertions passed"
    exit 0
  fi
  err "${FAILURES} shielded-night assertion(s) failed"
  exit 1
fi

BOOK_OUT="$(mktemp)"
trap 'rm -f "$BODY" "$HEADERS" "$BOOK_OUT"' EXIT

# `docker compose run` prints the container's stdout and stderr together, and the driver logs
# to stderr on purpose so that its ONE machine-readable line cannot be lost in them. Capture
# both to a file, show it, then read the line out of the file — never out of a pipe, because a
# grep that closes the pipe early makes the producer die of SIGPIPE under `pipefail`.
run_book_step() {  # run_book_step <label> <command...>
  local label="$1"; shift
  info "${label}"
  if "$@" >"$BOOK_OUT" 2>&1; then
    sed 's/^/      /' "$BOOK_OUT" >&2
    return 0
  fi
  sed 's/^/      /' "$BOOK_OUT" >&2
  return 1
}
book_field() {  # book_field <prefix> <key> — read key=value off the driver's result line
  # THE LEADING SPACE IS LOAD-BEARING. `.*` is greedy, so `.*nightBefore=` matches the LAST
  # place that substring occurs — and `snightBefore=` CONTAINS `nightBefore=`. Without the
  # space this read the sNight figures and printed them as NIGHT. The container's own
  # assertions were unaffected (they are made there, on the real values), but a gate that
  # prints the wrong numbers is exactly the kind of quiet wrongness a gate exists to prevent.
  sed -n "s/^${1} .* ${2}=\\([^ ]*\\).*$/\\1/p" "$BOOK_OUT" | head -1
}

if ! service_present kernel; then
  info "SKIP (offerfiles not up) — there is no order book on this stack, so nothing to post to"
  info "     bring it up with: ./up.sh --with offerfiles --with shielded-night"
elif [[ -z "$ADDRESS" ]]; then
  fail "cannot run the book chain: this stack published no contract address"
else
  BOOK_FAILED=0

  # ── the token registry ─────────────────────────────────────────────────────
  # The label the SPA shows for an sNight offer. Registered by the shielded-night-token-name
  # one-shot, which up.sh runs when both profiles are up. Asserted here rather than assumed:
  # without it the book shows 64 hex characters and nothing connects them to the NIGHT the
  # operator wrapped one page over.
  #
  # SINCE 00015 that one-shot PATCHES before it posts: the kernel seeds a SNIGHT row at the
  # PREVIEW contract's colour, which cannot exist here, so the row is UPDATEd to this stack's
  # own colour first (issues/00012). Four assertions follow from that, and they are the point
  # of this block: the name and the DERIVED colour meet on one record; there is exactly one
  # such record; the preview colour is gone; and running the one-shot a second time changes
  # nothing (step 0b).
  #
  # The kernel UPPERCASES a registered name (`String(body.name).trim().toUpperCase()`), so the
  # match is case-insensitive on purpose — `sNight` is stored as `SNIGHT`.
  if run_book_step "step 0/5  the sNight colour is named in the kernel's token registry" \
       dc run --rm --no-deps -T shielded-night-verify color; then
    SNIGHT_COLOR="$(book_field SNIGHT_RESULT color)"
  else
    SNIGHT_COLOR=""
  fi
  # `case`, not `[[ =~ ]]`: this must run under the macOS system bash (3.2), whose regex
  # support for bounded quantifiers is the one thing in it worth not relying on.
  case "$SNIGHT_COLOR" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) SNIGHT_COLOR_OK=1 ;;
    *) SNIGHT_COLOR_OK=0 ;;
  esac
  [[ "${#SNIGHT_COLOR}" -eq 64 ]] || SNIGHT_COLOR_OK=0
  if (( ! SNIGHT_COLOR_OK )); then
    fail "could not derive the sNight colour from the deployed contract"
    BOOK_FAILED=1
  else
    ok "sNight colour ${SNIGHT_COLOR:0:16}… derived from contract ${ADDRESS:0:16}…"
    KNOWN="$(curl -fsS --max-time 20 "${KERNEL_URL}/v1/known-tokens" 2>/dev/null || true)"
    # One `grep -o` per record rather than a JSON parser: this script must run on a clean
    # macOS box, where `jq` is not installed and python3 is not guaranteed to be either.
    # `grep -E`, not BRE `\|`: BSD grep (the one on a clean macOS box) has no `\|` alternation.
    # `tr '{' '\n'` puts each registry record on its own line so the colour and the name have
    # to belong to the SAME record — a colour registered under some other name would otherwise
    # match a name registered on some other colour.
    if printf '%s' "$KNOWN" | tr '{' '\n' | grep -Eqi "(${SNIGHT_COLOR}.*snight|snight.*${SNIGHT_COLOR})"; then
      ok "GET /v1/known-tokens names this colour sNight"

      # ── THE PATCH DID ITS JOB, AND ONLY ITS JOB (00015, spec FR-004) ────────
      # The kernel seeds a SNIGHT row at the PREVIEW contract's colour and the registry one-shot
      # patches it to this stack's own (images/shielded-night/sql/snight-registry-patch.sql;
      # organizer issues/00012). The assertion above proves the name and the derived colour meet
      # on ONE record; these two prove nothing else is left behind. `|| true` on the count:
      # `grep -c` exits 1 on zero, which is a legitimate answer and must not kill the script
      # under `pipefail`.
      SNIGHT_ROW_COUNT="$(printf '%s' "$KNOWN" | tr '{' '\n' | grep -ci '"name":"snight"' || true)"
      if [[ "${SNIGHT_ROW_COUNT:-0}" == "1" ]]; then
        ok "exactly one registry row is named SNIGHT"
      else
        fail "the registry holds ${SNIGHT_ROW_COUNT:-0} rows named SNIGHT, expected exactly 1"
        BOOK_FAILED=1
      fi
      if printf '%s' "$KNOWN" | grep -q "$PREVIEW_SNIGHT_COLOR"; then
        fail "the kernel's seeded PREVIEW sNight colour ${PREVIEW_SNIGHT_COLOR:0:16}… is still in the registry — the patch did not run (issues/00012)"
        BOOK_FAILED=1
      else
        ok "the seeded PREVIEW sNight colour ${PREVIEW_SNIGHT_COLOR:0:16}… is absent from the registry"
      fi

      # ── priced, not just named, at the FIXED 6 decimals (phase G, hardened in phase H2) ──
      # The registration one-shot posts the literal constant 6 (Q14's resolution: kernel PR #60
      # made 6 the correct, permanent value for NIGHT's own kernel-pricing decimals — see
      # images/shielded-night/entrypoint-token-name.sh). This assertion checks BOTH the fixed
      # value directly AND consistency with NIGHT's own row, so a kernel re-pin that regresses
      # the seed (or a re-pin to before PR #60) is caught here too, not only by the one-shot's
      # own preflight at registration time.
      SNIGHT_RECORD="$(printf '%s' "$KNOWN" | tr '{' '\n' | grep -Ei "${SNIGHT_COLOR}" | head -1)"
      NIGHT_RECORD="$(printf '%s' "$KNOWN" | tr '{' '\n' | grep -E '"token_color":"0{64}"' | head -1)"
      SNIGHT_DECIMALS="$(printf '%s' "$SNIGHT_RECORD" | sed -n 's/.*"decimals":\([0-9][0-9]*\).*/\1/p' | head -1)"
      NIGHT_DECIMALS="$(printf '%s' "$NIGHT_RECORD" | sed -n 's/.*"decimals":\([0-9][0-9]*\).*/\1/p' | head -1)"
      if [[ "$SNIGHT_DECIMALS" == "6" && "$NIGHT_DECIMALS" == "6" ]]; then
        ok "sNight and NIGHT are both registered at exactly 6 decimals"
      else
        fail "sNight decimals=${SNIGHT_DECIMALS:-none}, NIGHT decimals=${NIGHT_DECIMALS:-none} — expected BOTH exactly 6 (kernel PR #60 / Q14); GET /v1/quote will not be 1:1"
        BOOK_FAILED=1
      fi
      if printf '%s' "$SNIGHT_RECORD" | grep -q '"asset_id":"midnight-3"'; then
        ok "sNight is priced against midnight-3 (NIGHT's own reference asset)"
      else
        fail "sNight's known-tokens row carries no asset_id=midnight-3: ${SNIGHT_RECORD:0:200}"
        BOOK_FAILED=1
      fi

      # ── the quote itself, not just the ingredients ────────────────────────────
      # market_rate is pf/pt BEFORE any sponsorship discount is applied, so this is the real
      # price ratio the registration produced, not an artefact of the 2.5% default haircut
      # `suggested_to_amount` would otherwise bake in. Same asset, same decimals => the two
      # sides resolve to the SAME price-per-base-unit, and IEEE754 X/X is exactly 1 — so the
      # JSON literal is checked for, not approximated.
      QUOTE="$(curl -fsS --max-time 20 "${KERNEL_URL}/v1/quote?from_token=${SNIGHT_COLOR}&to_token=0000000000000000000000000000000000000000000000000000000000000000&from_amount=1000000" 2>/dev/null || true)"
      if printf '%s' "$QUOTE" | grep -q '"market_rate":1[,}]'; then
        ok "GET /v1/quote sNight->NIGHT market_rate is exactly 1 — the same asset, priced the same way"
      else
        fail "GET /v1/quote sNight->NIGHT is not ~1:1: ${QUOTE:0:300}"
        BOOK_FAILED=1
      fi

      # ── IDEMPOTENCE, PROVEN BY RUNNING IT AGAIN (spec FR-004 / SC-002) ──────
      # The registry one-shot is re-run on every `./up.sh`, so "it is safe to run twice" is a
      # claim this stack depends on rather than a nicety. It is asserted the only way that
      # means anything: run it, and require the patch to report `UPDATE 0` — the SQL is
      # idempotent by its own WHERE clause, not by a marker file (a marker would have to be
      # invalidated whenever ./down.sh -v gives the stack a new contract and a new colour).
      # The POST it makes afterwards is the same-colour 409, which is success.
      if run_book_step "step 0b/5 the registry patch is idempotent (a second run updates 0 rows)" \
           dc run --rm --no-deps -T shielded-night-token-name; then
        if grep -q 'registry patch: UPDATE 0' "$BOOK_OUT"; then
          ok "a second run of shielded-night-token-name reports UPDATE 0 and exits 0"
        else
          fail "the registry one-shot re-ran and exited 0, but did not report 'registry patch: UPDATE 0' — it patched something on a stack that was already patched"
          BOOK_FAILED=1
        fi
      else
        fail "re-running shielded-night-token-name failed — the one-shot is not idempotent, and up.sh runs it on every bring-up"
        BOOK_FAILED=1
      fi
    else
      fail "the kernel's token registry does not name ${SNIGHT_COLOR} sNight — the one-shot did not run, or the registry is disabled"
      BOOK_FAILED=1
    fi
  fi

  # ── the minted demo colour the offer will ask for ──────────────────────────
  # Read off the offerfiles-deploy volume through the kernel container, which mounts it
  # read-only. The colours derive from the OFFER-FILES contract address, so they are different
  # on every fresh stack and cannot be written down anywhere.
  WANT_TOKEN=""
  if (( ! BOOK_FAILED )); then
    MINTED="$(dc exec -T kernel cat /srv/offerfiles-deploy/minted-tokens.json 2>/dev/null || true)"
    WANT_TOKEN="$(printf '%s' "$MINTED" \
      | grep -o "\"${SNIGHT_BOOK_WANT_KEY}\"[[:space:]]*:[[:space:]]*\"[0-9a-f]*\"" \
      | head -1 | sed -e 's/.*:[[:space:]]*"//' -e 's/"$//' || true)"
    if [[ "${#WANT_TOKEN}" -ne 64 ]]; then
      fail "no ${SNIGHT_BOOK_WANT_KEY} colour on the offerfiles-deploy volume — the mint step did not publish one"
      BOOK_FAILED=1
    else
      ok "the offer will ask for ${SNIGHT_BOOK_WANT_KEY} (${WANT_TOKEN:0:16}…), a colour this stack minted"
    fi
  fi

  # ── 1. wrap ────────────────────────────────────────────────────────────────
  # The maker is SHIELDED_NIGHT_DRIVER_SEED, i.e. genesis-2 (Q6/D). The wrap leaves the sNight
  # in that wallet — unlike the round trips above, which end where they started — because the
  # next step spends it into an offer file.
  if (( ! BOOK_FAILED )); then
    if run_book_step "step 1/5  wrap ${SNIGHT_BOOK_AMOUNT} NIGHT into sNight on the maker wallet (proving…)" \
         dc run --rm --no-deps -T \
           -e "SNIGHT_SEED=${SHIELDED_NIGHT_DRIVER_SEED}" \
           -e "SNIGHT_AMOUNT=${SNIGHT_BOOK_AMOUNT}" \
           shielded-night-verify wrap; then
      W_NIGHT_BEFORE="$(book_field SNIGHT_RESULT nightBefore)"
      W_NIGHT_AFTER="$(book_field SNIGHT_RESULT nightAfter)"
      W_SN_BEFORE="$(book_field SNIGHT_RESULT snightBefore)"
      W_SN_AFTER="$(book_field SNIGHT_RESULT snightAfter)"
      ok "wrapped: NIGHT ${W_NIGHT_BEFORE} -> ${W_NIGHT_AFTER}, sNight ${W_SN_BEFORE} -> ${W_SN_AFTER} (exact deltas asserted in the container)"
    else
      fail "the wrap step failed — NIGHT never became sNight (see the output above)"
      BOOK_FAILED=1
    fi
  fi

  # ── 2. the offer file ──────────────────────────────────────────────────────
  # THE REPOSITORY'S OWN MAKER PATH, not a second implementation of the offer format:
  # `deploy/scripts/post-maker-offer.ts` is the script the `maker-offer` one-shot runs, it is
  # present at the pinned KERNEL_REF (not only on the solver branch), and every value it needs
  # is already an environment knob. So the sNight offer differs from the stack's own seeding
  # offer in exactly three variables: the give colour, the seed, and the amounts.
  #
  # `--no-deps` because the stack is already up, and `run` on the `kernel` SERVICE because its
  # definition already carries the endpoints, the storage password and the minted-colours
  # volume. No compose service is added: one that existed would be started by every `up.sh`.
  if (( ! BOOK_FAILED )); then
    if run_book_step "step 2/5  post a real MIP-0005 offer file: give ${SNIGHT_BOOK_AMOUNT} sNight, want ${SNIGHT_BOOK_WANT_AMOUNT} ${SNIGHT_BOOK_WANT_KEY} (proving…)" \
         dc run --rm --no-deps -T \
           -e "ZSWAP_API=http://kernel:9999" \
           -e "MAKER_SEED=${SHIELDED_NIGHT_DRIVER_SEED}" \
           -e "GIVE_TOKEN=${SNIGHT_COLOR}" \
           -e "WANT_TOKEN=${WANT_TOKEN}" \
           -e "GIVE_AMOUNT=${SNIGHT_BOOK_AMOUNT}" \
           -e "WANT_AMOUNT=${SNIGHT_BOOK_WANT_AMOUNT}" \
           --entrypoint bun kernel run deploy/scripts/post-maker-offer.ts; then
      ok "the offer file was accepted and reached status 'live' in the kernel book"
    else
      fail "posting the sNight offer file failed (see the output above)"
      BOOK_FAILED=1
    fi
  fi

  # ── 3. it is really in the book, on the sNight colour ──────────────────────
  # Queried BY COLOUR through the kernel's own filter, so this is not "some offer exists": the
  # book is asked for offers GIVING sNight and must answer with ours, both amounts exact.
  if (( ! BOOK_FAILED )); then
    BOOKED="$(curl -fsS --max-time 30 "${KERNEL_URL}/v1/offers?token=${SNIGHT_COLOR}&direction=GIVING&limit=100" 2>/dev/null || true)"
    # The amount is declared `string` in the DTO but is serialised by the pg driver, so accept
    # it quoted or bare rather than betting the gate on a driver detail.
    if printf '%s' "$BOOKED" | grep -Eq "\"token\":\"${SNIGHT_COLOR}\",\"amount\":\"?${SNIGHT_BOOK_AMOUNT}\"?[,}]"; then
      ok "GET /v1/offers?token=<sNight>&direction=GIVING lists an offer GIVING ${SNIGHT_BOOK_AMOUNT} sNight"
    else
      fail "the book does not list an offer giving ${SNIGHT_BOOK_AMOUNT} of ${SNIGHT_COLOR}"
      printf '%s\n' "$BOOKED" | head -c 2000 | sed 's/^/      /' >&2
      BOOK_FAILED=1
    fi
    if printf '%s' "$BOOKED" | grep -Eq "\"token\":\"${WANT_TOKEN}\",\"amount\":\"?${SNIGHT_BOOK_WANT_AMOUNT}\"?[,}]"; then
      ok "…and WANTING ${SNIGHT_BOOK_WANT_AMOUNT} of ${SNIGHT_BOOK_WANT_KEY} — native NIGHT is now tradable on this book"
    else
      fail "the listed offer does not want ${SNIGHT_BOOK_WANT_AMOUNT} of ${WANT_TOKEN}"
      BOOK_FAILED=1
    fi
  fi

  # ── 4. a second wallet takes it ────────────────────────────────────────────
  #
  # A DIRECT TAKE, and that is a deliberate choice worth stating. Taking an Offer File means
  # balancing the maker's deliberately-unbalanced transaction and submitting it — no relay and
  # no solver are involved, which is the entire point of the format. The `solver` profile's
  # relay lane CANNOT carry this pair: the COW solver quotes from inventory it holds, its
  # provisioning mints only the demo colours, and it has no lane to acquire sNight (which
  # exists only by wrapping NIGHT through a contract that profile knows nothing about). So the
  # take is gated on `offerfiles`, like the rest of the chain, and what the solver profile
  # would add — a relay-brokered fill of this same offer — is reported as a SKIP.
  if (( ! BOOK_FAILED )); then
    if service_present solver; then
      info "note: the solver profile is up, but the relay lane cannot quote an sNight pair"
      info "      (the COW solver holds no sNight and has no way to acquire it) — the offer is"
      info "      taken directly instead, which is what an Offer File is for"
    else
      info "SKIP (solver not up) — no relay-brokered fill of this offer; taking it directly"
    fi
    if run_book_step "step 4/5  the taker balances the offer file and settles it on chain (funding + proving — this is the long one)" \
         dc run --rm --no-deps -T \
           -v "${REPO_ROOT}/scripts/driver:/app/stack-driver:ro" \
           -e "ZSWAP_API=http://kernel:9999" \
           -e "TAKER_SEED=${SNIGHT_BOOK_TAKER_SEED}" \
           -e "FUNDER_SEED=${SNIGHT_BOOK_FUNDER_SEED}" \
           -e "SNIGHT_COLOR=${SNIGHT_COLOR}" \
           -e "WANT_TOKEN=${WANT_TOKEN}" \
           -e "GIVE_AMOUNT=${SNIGHT_BOOK_AMOUNT}" \
           -e "WANT_AMOUNT=${SNIGHT_BOOK_WANT_AMOUNT}" \
           --entrypoint bun kernel run stack-driver/take-snight-offer.ts; then
      T_SN_BEFORE="$(book_field SNIGHT_TAKE_RESULT snightBefore)"
      T_SN_AFTER="$(book_field SNIGHT_TAKE_RESULT snightAfter)"
      ok "the offer is CONSUMED on chain; the taker's sNight went ${T_SN_BEFORE} -> ${T_SN_AFTER} and it paid exactly ${SNIGHT_BOOK_WANT_AMOUNT}"
    else
      fail "the take failed — the sNight offer file did not settle (see the output above)"
      BOOK_FAILED=1
    fi
  fi

  # ── 5. and the taker unwraps what it bought ────────────────────────────────
  # THE FULL CIRCLE, and the strongest single claim in this section: this wallet never wrapped
  # anything. Its sNight arrived inside somebody else's offer file, and the coin is discovered
  # from its own synced state rather than carried from the mint. That is the property the page
  # itself cannot demonstrate (docs/KNOWN-LIMITATIONS.md: the browser can only unwrap coins it
  # minted, because it remembers their nonces in localStorage).
  if (( ! BOOK_FAILED )); then
    if run_book_step "step 5/5  the taker converts the sNight it BOUGHT back to native NIGHT (proving…)" \
         dc run --rm --no-deps -T \
           -e "SNIGHT_SEED=${SNIGHT_BOOK_TAKER_SEED}" \
           -e "SNIGHT_AMOUNT=${SNIGHT_BOOK_AMOUNT}" \
           shielded-night-verify unwrap; then
      U_NIGHT_BEFORE="$(book_field SNIGHT_RESULT nightBefore)"
      U_NIGHT_AFTER="$(book_field SNIGHT_RESULT nightAfter)"
      ok "the taker's NIGHT went ${U_NIGHT_BEFORE} -> ${U_NIGHT_AFTER} (+${SNIGHT_BOOK_AMOUNT}) — the circle is closed"
    else
      fail "the taker could not unwrap the sNight it bought (see the output above)"
      BOOK_FAILED=1
    fi
  fi

  if (( BOOK_FAILED == 0 )); then
    ok "book chain: NIGHT -> sNight -> offer file -> taken -> NIGHT, with exact balances at every step"
  fi
fi

echo
if (( FAILURES == 0 )); then
  ok "shielded-night assertions passed"
  exit 0
fi
err "${FAILURES} shielded-night assertion(s) failed"
exit 1
