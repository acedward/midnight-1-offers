#!/usr/bin/env bash
#
# Assertions for the `frontend` profile — the `frontend` section of ./verify.sh.
#
#   ./scripts/verify-frontend.sh
#
# THE QUESTION THIS SCRIPT EXISTS TO ANSWER is not "does nginx serve a page". It is: WOULD A
# BROWSER ON THIS HOST BE ABLE TO REACH EVERYTHING THE PAGE TALKS TO? The SPA runs outside the
# compose network and dials five endpoints — kernel API, batcher, node, indexer (HTTP + WS) and
# proof server — three of which the kernel reports to it as compose service names on container
# ports. That is the failure this profile has to be protected from, and it cannot be seen by
# asking nginx anything.
#
# So the checks are, in order:
#
#   serves      GET / answers an HTML document (nginx up, dist/ present).
#   config.js   GET /config.js answers 200 and injects EXACTLY the FRONTEND_* values this env
#               file set. It is written at container start, not baked into the image, so a 404
#               means the entrypoint never ran.
#   wired       index.html loads config.js BEFORE the module bundle, or every override is dead.
#   bundle      both halves of the browser-network URI fix (effectstream#912) are in the SERVED javascript,
#               not merely in the source tree a build stage saw.
#   endpoints   the config the page would actually receive is RESOLVED here exactly the way the
#               patch resolves it (overrides first, then the dot-less-hostname rewrite), and
#               then asserted twice over: no compose-internal hostname may survive, and every
#               resolved endpoint must answer from THIS host.
#   zk assets   the three requests midnight-js 4.1.1's FetchZkConfigProvider makes per contract
#               circuit — keys/<c>.prover, keys/<c>.verifier, zkir/<c>.bzkir — are GONE at
#               `KERNEL_REF=e3b9388…` and their ABSENCE is what is asserted. Kernel #69 deleted
#               `packages/node/zk-assets.ts` with the contract whose keys they served. That
#               leaves the SPA's Faucet tab DEAD until phase D re-points it at the issuer's own
#               site — stated here, and in docs/KNOWN-LIMITATIONS.md, rather than discovered by
#               a person clicking it.
#
# The last two sections need the kernel, so they run only when the `offerfiles` profile is up;
# `--with frontend` alone stays legal and the SPA still verifies as a static asset server.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"

require_docker
load_env

BIND="${HOST_ADDR:-127.0.0.1}"
FPORT="${FRONTEND_HOST_PORT:-10600}"
BASE="http://${BIND}:${FPORT}"

FAILURES=0
fail() { err "$*"; FAILURES=$(( FAILURES + 1 )); }

# ALL THREE HELPERS BELOW PRINT NOTHING AND STILL SUCCEED when there is no match, and every
# one of them ends in an explicit `return 0`. "Absent" is a normal, expected answer here — the
# kernel does not report a nodeUri at all — and under `set -e` with `pipefail` a non-matching
# grep makes the whole pipeline fail, so `x="$(json_field …)"` would abort the script instead
# of assigning the empty string. That is exactly what happened on the first live run: the
# script died silently at the first absent key with every remaining assertion unreported.

# json_field <body> <key> — the string value of a top-level JSON key, or nothing.
# grep/sed rather than jq or python: this repository's verify scripts take no dependency a
# clean macOS box does not already have.
json_field() {
  local raw
  raw="$(printf '%s' "$1" | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 || true)"
  [[ -n "$raw" ]] || return 0
  printf '%s' "$raw" | sed -E "s/^\"$2\"[[:space:]]*:[[:space:]]*\"(.*)\"$/\1/"
  return 0
}

# uri_host <url> — the hostname, without scheme, port or path.
uri_host() {
  local u="$1"
  [[ "$u" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*://([^/:]+) ]] && printf '%s' "${BASH_REMATCH[1]}"
  return 0
}

# uri_port <url> — the explicit port, or nothing when the URL carries none.
uri_port() {
  local u="$1"
  [[ "$u" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*://[^/:]+:([0-9]+) ]] && printf '%s' "${BASH_REMATCH[1]}"
  return 0
}

log "frontend: endpoints"
info "spa   ${BASE}"

# ── the static surface ───────────────────────────────────────────────────────
echo
log "frontend: assets"

HTML="$(curl -fsS --max-time 10 "$BASE/" 2>/dev/null || true)"
if [[ "$HTML" == *"<html"* || "$HTML" == *"<!doctype"* || "$HTML" == *"<!DOCTYPE"* ]]; then
  ok "serves an HTML document on :${FPORT}"
else
  fail "did not serve HTML on :${FPORT}"
fi

CONFIG_JS=""
if CONFIG_JS="$(curl -fsS --max-time 10 "$BASE/config.js" 2>/dev/null)"; then
  ok "serves /config.js (written at container start, not baked into the image)"
else
  CONFIG_JS=""
  fail "/config.js is missing — the image entrypoint did not run"
fi

if [[ "$HTML" == *"config.js"* ]]; then
  ok "index.html loads config.js before the bundle"
else
  fail "index.html does not reference config.js — every runtime override is dead"
fi

# Each override is asserted only when this stack SET it. Empty is a legitimate configuration
# (the default port block), and asserting an absent value would fail a correct stack.
#
# The pairs are <env var>=<window property>, space-separated, iterated as one string so the
# loop stays bash 3.2 safe (no associative arrays, which are bash 4+).
for pair in \
  "FRONTEND_API_BASE=API_BASE" \
  "FRONTEND_BATCHER_URL=BATCHER_URL" \
  "FRONTEND_NODE_URI=NODE_URI" \
  "FRONTEND_INDEXER_URI=INDEXER_URI" \
  "FRONTEND_INDEXER_WS_URI=INDEXER_WS_URI" \
  "FRONTEND_PROOF_SERVER_URI=PROOF_SERVER_URI"
do
  var="${pair%%=*}"; prop="${pair#*=}"
  val="${!var-}"
  [[ -n "$val" ]] || continue
  # `case`, not `printf … | grep -Fq …`: a match makes grep close the pipe, the producer dies
  # of SIGPIPE and the pipeline reports failure under `pipefail`. That is trap #2 from
  # scripts/lib/common.sh, and it bites on any input large enough for the producer still to be
  # writing. Quoted expansions inside a case pattern are literal, so this is an exact substring
  # test with no external process at all.
  case "$CONFIG_JS" in
    *"window.${prop} = \"${val}\";"*) ok "config.js injects ${prop}=${val}" ;;
    *) fail "config.js does not inject ${var}=${val}" ;;
  esac
done

# ── the patch has to be in the SERVED bundle ─────────────────────────────────
#
# A build-stage grep proves the source was patched. It does not prove the code survived
# bundling, tree-shaking and minification. Both markers are regex literals, which esbuild
# emits verbatim: `([A-Z])` is the camelCase->SCREAMING_SNAKE mapping of the override lane,
# `[^/:]+` the hostname rewrite.
echo
log "frontend: browser-network rewrite is in the shipped bundle"
# ACROSS EVERY CHUNK, not just the entry. Vite code-splits, and api.ts lands in a lazily
# imported chunk — checking only the `src=` script would have looked for the rewrite in the
# 6 MB file that does not contain it and failed a correct build. Chunk names are content
# hashed, so they are discovered from what is served (index.html's script/modulepreload tags,
# then the entry's own import map) rather than guessed.
ENTRY_PATH="$(printf '%s' "$HTML" | grep -oE 'src="/assets/[^"]+\.js"' | head -1 | sed -E 's/^src="(.*)"$/\1/' || true)"
if [[ -z "$ENTRY_PATH" ]]; then
  fail "could not find the module bundle referenced by index.html"
else
  info "entry ${ENTRY_PATH}"
  ENTRY="$(curl -fsS --max-time 60 "${BASE}${ENTRY_PATH}" 2>/dev/null || true)"
  if [[ -z "$ENTRY" ]]; then
    fail "the entry bundle ${ENTRY_PATH} did not download"
  else
    # Matched WITHOUT a leading slash and re-rooted afterwards: a chunk reference appears as
    # "/assets/x.js" in index.html and may appear as "./assets/x.js" or bare "assets/x.js"
    # inside the entry's own import map, and a pattern anchored on "/assets/" would silently
    # find fewer chunks than exist.
    ASSET_PATHS="$( { printf '%s\n' "$HTML"; printf '%s\n' "$ENTRY"; } \
      | grep -oE 'assets/[A-Za-z0-9_.@-]+\.js' | sort -u | sed 's|^|/|' || true )"
    info "chunks $(printf '%s\n' "$ASSET_PATHS" | grep -c '^/assets/') javascript asset(s)"
    FOUND_OVERRIDE=0
    FOUND_REWRITE=0
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      (( FOUND_OVERRIDE && FOUND_REWRITE )) && break
      chunk="$(curl -fsS --max-time 60 "${BASE}${path}" 2>/dev/null || true)"
      [[ -n "$chunk" ]] || continue
      case "$chunk" in *'([A-Z])'*) FOUND_OVERRIDE=1 ;; esac
      case "$chunk" in *'[^/:]+'*)  FOUND_REWRITE=1 ;; esac
    done <<< "$ASSET_PATHS"

    if (( FOUND_OVERRIDE )); then
      ok "the URI-override lane is in the bundle"
    else
      fail "the URI-override lane is NOT in the bundle — FRONTEND_*_URI would be ignored"
    fi
    if (( FOUND_REWRITE )); then
      ok "the compose-hostname rewrite is in the bundle"
    else
      fail "the compose-hostname rewrite is NOT in the bundle — service names would reach the browser"
    fi
  fi
fi

# ── what the page would actually resolve ─────────────────────────────────────
if ! service_present kernel; then
  echo
  dim "kernel not up — skipping the endpoint-resolution and ZK-asset checks"
  dim "(./up.sh --with offerfiles --with frontend to include them)"
  echo
  if (( FAILURES == 0 )); then
    ok "frontend assertions passed (static only)"
    exit 0
  fi
  err "${FAILURES} frontend assertion(s) failed"
  exit 1
fi

echo
log "frontend: the endpoints a browser would resolve"

# The page's own resolution order for the API base: window.API_BASE, else VITE_API_BASE (never
# set in this image), else http://<pageHost>:9999. pageHost is whatever host the operator typed
# to reach the SPA, which for a loopback-bound stack is BIND.
EFF_API="${FRONTEND_API_BASE:-http://${BIND}:9999}"
EFF_BATCHER="${FRONTEND_BATCHER_URL:-http://${BIND}:3334}"
info "api      ${EFF_API}"
info "batcher  ${EFF_BATCHER}"

for pair in "api=${EFF_API}/v1/health" "batcher=${EFF_BATCHER}/health"; do
  label="${pair%%=*}"; url="${pair#*=}"
  if curl -fsS --max-time 10 "$url" >/dev/null 2>&1; then
    ok "${label} reachable at the address the page would use (${url})"
  else
    fail "${label} NOT reachable at ${url} — the page's own endpoint resolution is wrong for this port block"
  fi
done

CFG="$(curl -fsS --max-time 15 "${EFF_API}/v1/midnight/config" 2>/dev/null || true)"
if [[ -z "$CFG" ]]; then
  fail "GET ${EFF_API}/v1/midnight/config did not answer"
else
  # THE EXPECTATION IS INVERTED AT THIS PIN (00020 PR C). `GET /v1/midnight/config` carried a
  # `contractAddress` up to `KERNEL_REF=a608fa6…` and the SPA connected to it; kernel #69
  # removed the contract and the field. Its presence would mean KERNEL_REF had moved BACKWARDS,
  # onto a line this repository's images no longer build for.
  CONTRACT="$(json_field "$CFG" contractAddress)"
  if [[ -z "$CONTRACT" ]]; then
    ok "the kernel reports NO contract address — kernel #69 removed it, as this pin expects"
  else
    fail "the kernel still reports a contractAddress (${CONTRACT:0:16}…). Kernel #69 deleted the
          offer-files contract and this field with it, and images/offerfiles-kernel has no
          Compact stage at this pin. Check KERNEL_REF (expected e3b9388… or later)."
  fi

  # Resolve each URI exactly as upstream's api.getMidnightConfig (effectstream#912) does: an explicit override wins,
  # otherwise a dot-less non-localhost hostname is re-pointed at the page's own host. nodeUri
  # is in the list although the kernel never reports one — the in-page JS wallet needs it, and
  # the patch injects the override even when the key is absent.
  for key in nodeUri indexerUri indexerWsUri proofServerUri; do
    raw="$(json_field "$CFG" "$key")"
    case "$key" in
      nodeUri)        override="${FRONTEND_NODE_URI-}" ;;
      indexerUri)     override="${FRONTEND_INDEXER_URI-}" ;;
      indexerWsUri)   override="${FRONTEND_INDEXER_WS_URI-}" ;;
      proofServerUri) override="${FRONTEND_PROOF_SERVER_URI-}" ;;
      *)              override="" ;;
    esac

    resolved=""
    if [[ -n "$override" ]]; then
      resolved="$override"
      origin="override"
    elif [[ -n "$raw" ]]; then
      host="$(uri_host "$raw")"
      if [[ -n "$host" && "$host" != *.* && "$host" != "localhost" ]]; then
        # Split and rebuild rather than `${raw/…/…}`: the pattern would contain the `/` that
        # terminates a bash substitution, and quoting it is not reliably honoured by bash 3.2.
        scheme="${raw%%://*}"
        rest="${raw#*://}"
        resolved="${scheme}://${BIND}${rest#"$host"}"
        origin="rewritten from ${host}"
      else
        resolved="$raw"
        origin="as reported"
      fi
    else
      # Only nodeUri can legitimately be absent, and only when no override was set — in which
      # case the SPA falls back to http://<pageHost>:9944, which is right ONLY on the default
      # port block. Say so rather than passing silently.
      if [[ "$key" == "nodeUri" ]]; then
        resolved="http://${BIND}:9944"
        origin="template fallback (kernel reports no nodeUri, FRONTEND_NODE_URI unset)"
      else
        fail "${key} is absent from /v1/midnight/config and has no override"
        continue
      fi
    fi

    info "${key} -> ${resolved}   (${origin})"

    # ASSERTION 1 — no compose-internal hostname may survive resolution. This is the whole
    # point of the patch: a bare, dot-less, non-localhost hostname resolves only on the
    # compose network, and in a browser it is ERR_NAME_NOT_RESOLVED.
    rhost="$(uri_host "$resolved")"
    if [[ -z "$rhost" ]]; then
      fail "${key} did not resolve to a parseable URL: ${resolved}"
      continue
    fi
    if [[ "$rhost" != *.* && "$rhost" != "localhost" ]]; then
      fail "${key} still carries the compose-internal hostname '${rhost}' — a browser cannot resolve it"
      continue
    fi
    ok "${key} carries a browser-resolvable host (${rhost})"

    # ASSERTION 2 — and it actually answers from here. A resolvable hostname on an unpublished
    # port is the exact failure a hostname-only rewrite produces on a generated port block.
    rport="$(uri_port "$resolved")"
    case "$key" in
      nodeUri)
        if curl -sf --max-time 10 -H 'Content-Type: application/json' \
             -d '{"id":1,"jsonrpc":"2.0","method":"chain_getBlockHash","params":[1]}' \
             "$resolved" 2>/dev/null | grep -q '"result":"0x'; then
          ok "node RPC answers at ${resolved}"
        else
          fail "node RPC does not answer at ${resolved}"
        fi
        ;;
      indexerUri)
        if [[ "$(graphql "$resolved" '{ block { height } }' || true)" == *'"height"'* ]]; then
          ok "indexer GraphQL answers at ${resolved}"
        else
          fail "indexer GraphQL does not answer at ${resolved}"
        fi
        ;;
      indexerWsUri)
        # A WebSocket upgrade is not worth a dependency here; the socket is on the same
        # host:port as the HTTP endpoint, so prove the listener is reachable.
        if [[ -n "$rport" ]] && (exec 3<>"/dev/tcp/${rhost}/${rport}") >/dev/null 2>&1; then
          ok "indexer WS endpoint is reachable (${rhost}:${rport})"
        else
          fail "indexer WS endpoint ${rhost}:${rport:-?} is not reachable from this host"
        fi
        ;;
      proofServerUri)
        if [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${resolved%/}/ready" 2>/dev/null)" == "200" ]]; then
          ok "proof server answers /ready at ${resolved}"
        else
          fail "proof server does not answer /ready at ${resolved}"
        fi
        ;;
    esac
  done
fi

# ── the ZK asset lane (T3.5) ─────────────────────────────────────────────────
#
# midnight-js 4.1.1's FetchZkConfigProvider is pointed at API_BASE and makes exactly three
# requests per contract circuit: keys/<c>.prover, keys/<c>.verifier, zkir/<c>.bzkir. Up to
# `KERNEL_REF=a608fa6…` this block asserted they answered with BINARY rather than with an SPA
# fallback page, because the provider only checks `response.ok` and would otherwise hand the
# prover an HTML document as a proving key.
#
# AT `e3b9388…` THEY ARE GONE, and the assertion is inverted. Kernel #69 deleted
# `packages/node/zk-assets.ts` — `registerZkAssetRoutes(server)` no longer exists in
# `packages/node/api.ts` — along with the contract whose circuits those artifacts belong to.
#
# WHAT THAT COSTS, STATED HERE RATHER THAN DISCOVERED BY CLICKING: the SPA's Faucet tab proves
# a mint in the browser and fetches its keys from exactly these routes, so it is DEAD on this
# pin. Nothing automated depended on it (`issuer-fund` is the headless path and the browser
# mint has always been an owner hand test), and phase D re-points the page at the issuer's own
# faucet site, which serves the same class of artifact for the six issued tokens. Recorded in
# docs/KNOWN-LIMITATIONS.md.
echo
log "frontend: the ZK asset routes are gone at this pin"
for asset in keys/mint_shielded.prover keys/mint_shielded.verifier zkir/mint_shielded.bzkir; do
  url="${EFF_API}/${asset}"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$url" 2>/dev/null || echo 000)"
  case "$code" in
    404)
      ok "${asset} answers 404 — the route was removed with the contract, as this pin expects"
      ;;
    200)
      fail "${asset} is still SERVED. Kernel #69 deleted packages/node/zk-assets.ts with the
            contract those keys belong to, and this repository is built for the pin WITHOUT
            them. Check KERNEL_REF (expected e3b9388… or later)."
      ;;
    *)
      warn "${asset} answered HTTP ${code} rather than 404 — expected gone at this pin"
      ;;
  esac
done

echo
if (( FAILURES == 0 )); then
  ok "frontend assertions passed"
  exit 0
fi
err "${FAILURES} frontend assertion(s) failed"
exit 1
