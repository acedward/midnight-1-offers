#!/usr/bin/env bash
#
# Assertions for the `issuer` profile — the `issuer` section of ./verify.sh.
#
#   ./scripts/verify-issuer.sh
#
# WHAT IT PROVES, and why each check is here rather than assumed:
#
#   the registry      `issuer-registry` validates the published `metadata.undeployed.json`
#                     against BOTH `schema/metadata.schema.json` and the pinned tree's own
#                     browser-safe semantic validator — the same two gates the faucet site
#                     applies before it will show a token — and requires `status: ready` with
#                     SIX active deployments. A file that passes one and fails the other is a
#                     file the site will refuse, so both are checked.
#   the six tokens    each of TWBTC/TWETH/TWUSDC/TWUSDM/UTWUSDC/UTWBTC appears exactly once,
#                     with a 64-hex token id, the right decimals (8/18/6/6/6/8) and the right
#                     privacy. Every price and every mint amount in this stack is scaled by
#                     those decimals, so a silent 8 -> 9 is wrong by a factor of ten
#                     everywhere at once.
#   the faucet site   `GET /?network=undeployed` answers 200 with the SPA shell, and
#                     `GET /metadata.undeployed.json` answers 200 with a JSON content type,
#                     `Access-Control-Allow-Origin: *` and the registry revision the file
#                     itself carries. The content type is not a nicety: the SPA's own
#                     `fetchRegistry()` refuses a body that is not `application/json`, and
#                     without the exact-match nginx location a missing registry would answer
#                     200 with index.html — which is the one failure that looks like success.
#   the ZK lane       one prover and one verifier key are served as BYTES, not as the app
#                     shell. midnight-js's FetchZkConfigProvider only checks `response.ok`, so
#                     an HTML shell would be handed to the prover as a proving key.
#   FUNDING           `issuer-fund <TOKEN> <base-units> <seed>` mints exactly
#                     ISSUER_VERIFY_FUND_AMOUNT of ISSUER_VERIFY_FUND_TOKEN to
#                     ISSUER_VERIFY_FUND_SEED, and the RECIPIENT's own balance for that colour
#                     is read back and must have moved by EXACTLY that amount. This is the
#                     assertion the whole profile exists for: from phase C onwards the solver,
#                     the maker, the poster and the e2e driver are funded by this one command,
#                     and "the transaction was accepted" is not the claim any of them needs.
#   the kernel        ONLY when the `offerfiles` profile is up: `GET /v1/known-tokens` holds
#                     the six NAMES at the registry's own colours and decimals, with ZERO of
#                     the six PREPROD PHANTOM colours the kernel's `000-init.sql` seeds — and
#                     the current pin's DEVA/DEVB/DEVU rows still present, because until
#                     phase C retires the kernel's faucet the two token sets coexist.
#   RESUME            a second `issuer-deploy` deploys NOTHING: it prints six `[resume]` lines,
#                     exits 0, and the registry's `registryRevision` is byte-identical
#                     afterwards. A one-shot that silently redeployed would give the stack six
#                     new colours and orphan every coin already minted, and the only place
#                     that is cheap to catch is here.
#
# WHAT IT DELIBERATELY DOES NOT PROVE. The BROWSER mint. The faucet site mints through a
# connected dApp-connector 4.x wallet (Lace) and the wallet does the proving, so there is no
# headless path through it at all — by design, and it is why `issuer-fund` exists. The browser
# flow is the OWNER'S HAND TEST; docs/OPERATIONS.md carries the steps.
#
# It also does not re-verify the six contracts ON CHAIN by default. The pinned repository's own
# read-only verification does that — every verifier key against chain state, the immutable
# metadata, the derived token id, the artifact digest, the recorded source revision and the
# deploy action at the recorded height — and `issuer-deploy` already ran it once per contract at
# deploy time. It takes minutes, so here it is opt-in:
#
#   ISSUER_VERIFY_ONCHAIN=1 ./scripts/verify-issuer.sh
#
# ── THE ONE SIDE EFFECT THIS SCRIPT HAS ─────────────────────────────────────
# It MINTS. One whole TWBTC lands in e2e-taker's wallet and stays there. That wallet starts
# empty at genesis (measured, wallets/wallets.json), so the read-back is unambiguous — and
# `verify.sh` runs this section LAST for exactly this reason, after every section that makes
# assertions about that wallet.
#
# ── bash 3.2 AND `pipefail` ─────────────────────────────────────────────────
# Every count/extract helper below ends in `|| true`. Under `set -euo pipefail` a `grep` or
# `sed -n` that legitimately matches NOTHING exits 1, `pipefail` makes that the pipeline's
# status, and `set -e` then kills the script from inside `$( )` — silently, at exactly the
# empty state the check exists to handle. That cost one gate run in 00011 phase B; it is a
# design rule here rather than a lesson to relearn.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"

require_docker
load_env
# Every fragment, not just issuer: `dc exec`/`dc run` must resolve the service, and naming one
# profile makes compose call every other profile's containers orphans on each invocation.
use_all_profiles

BIND="${HOST_ADDR:-127.0.0.1}"
FAUCET="http://${BIND}:${FAUCET_HOST_PORT:-10500}"
KERNEL="http://${BIND}:${KERNEL_HOST_PORT:-9999}"

FAILURES=0
fail() { err "$*"; FAILURES=$(( FAILURES + 1 )); }

# ── the six canonical tokens, and what each must be ─────────────────────────
# Stated HERE as well as in the registry so this script can catch a registry that is
# internally consistent and wrong. `<NAME>:<decimals>:<privacy>`, in the pinned tree's
# canonical order. bash 3.2 has no associative arrays; a space-separated list of triples is
# what every other script in this repository uses for the same reason.
EXPECTED_TOKENS="TWBTC:8:shielded TWETH:18:shielded TWUSDC:6:shielded TWUSDM:6:shielded UTWUSDC:6:unshielded UTWBTC:8:unshielded"

# The SIX PREPROD PHANTOM COLOURS the kernel's own packages/database/migrations/000-init.sql
# seeds beside those names at `main` @ e3b9388 (from the pinned Preprod registry revision
# ebd5eaba…). None of them can exist on an `undeployed` chain — this stack deploys its own six
# contracts and derives its own six colours — so a registry that still names one of them is a
# registrar that did not run, or ran and was overwritten.
#
# They are listed even though the kernel pin this stack runs TODAY (a608fa6) seeds none of
# them: the assertion has to be right at the pin phase C moves to, and an assertion that only
# becomes real later is one nobody remembers to add.
PHANTOM_COLOURS="b11bd7c7ac94a584ef66e53e1ecd91a304cc452a5ad67399ae82e5919d2058dc 087d1d5d35316e7e25a1b069ac302742547d784f46410deb4d20266fd3ea9f1f a5c902be8fff1a0c3f10a926b24c3eaa8a93215535915b5af47d2c6a59febab5 931ceb35c81dc57978fea79de042a4a31f7694d012d0d79b351789502fc7b6ee 4ecbf451771bebdc0e9ad7aed27405b7f5dee20121bcf0be5746a4ef22748e9f be3354fbcec9efa8c2d75eb64ab49a7fd2bda9cfa76b3cf6ede47fef63b6878e"

# ── extractors, every one of them `|| true` ─────────────────────────────────

# jrec <json> <grep-ere> — the flattened JSON object matching <grep-ere>. `tr '{' '\n'` turns
# each object into a line; the same idiom verify-kernel.sh and verify-prices.sh use on this
# endpoint, and it is enough because none of the objects read here nests another.
jrec() {
  printf '%s' "$1" | tr '{' '\n' | grep -E -- "$2" | head -1 || true
}
# jstr <record> <key> — a string field's value.
jstr() {
  printf '%s' "$1" | sed -n "s/.*\"$2\":\"\\([^\"]*\\)\".*/\\1/p" | head -1 || true
}
# jnum <record> <key> — an unquoted integer field.
# `[0-9][0-9]*`, never the GNU-only `[0-9]\+`: BSD sed silently matches nothing (00007 H2).
jnum() {
  printf '%s' "$1" | sed -n "s/.*\"$2\":\\([0-9][0-9]*\\).*/\\1/p" | head -1 || true
}
# field <line> <key> — `key=value` out of one of the issuer scripts' own record lines.
field() {
  printf '%s' "$1" | sed -n "s/.* $2=\\([^ ]*\\).*/\\1/p" | head -1 || true
}
# httpcode <url> — the status code, or 000 when nothing answered.
httpcode() {
  curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$1" 2>/dev/null || printf '000'
}

# ── 1. THE REGISTRY, through the one reader this stack has ──────────────────
#
# `issuer-registry` is the SAME script `issuer-deploy` runs after publishing and
# `issuer-registrar` runs before registering anything, so "the registry is valid" has one
# implementation in three places rather than three that can disagree.
log "issuer: the published registry"
REGISTRY_RC=0
REGISTRY_OUT="$(dc run --rm --no-deps -T issuer-registry 2>&1)" || REGISTRY_RC=$?
printf '%s\n' "$REGISTRY_OUT" | sed 's/^/      /'
if (( REGISTRY_RC != 0 )); then
  fail "issuer-registry exited ${REGISTRY_RC} — the published registry did not validate"
else
  ok "metadata.undeployed.json validates against schema/metadata.schema.json AND the semantic validator"
fi

SUMMARY_LINE="$(printf '%s\n' "$REGISTRY_OUT" | grep '^ISSUER_REGISTRY ' | head -1 || true)"
TOKEN_LINES="$(printf '%s\n' "$REGISTRY_OUT" | grep '^ISSUER_TOKEN ' || true)"

REG_STATUS="$(field "$SUMMARY_LINE" status)"
REG_ACTIVE="$(field "$SUMMARY_LINE" active)"
REG_REVISION="$(field "$SUMMARY_LINE" revision)"
REG_NETWORK="$(field "$SUMMARY_LINE" network)"

if [[ "$REG_STATUS" == "ready" ]]; then
  ok "registry status is ready"
else
  fail "registry status is '${REG_STATUS:-<unreadable>}', expected ready"
fi
if [[ "$REG_NETWORK" == "undeployed" ]]; then
  ok "registry network is undeployed"
else
  fail "registry network is '${REG_NETWORK:-<unreadable>}', expected undeployed"
fi
if [[ "$REG_ACTIVE" == "6" ]]; then
  ok "registry selects 6 active deployments"
else
  fail "registry selects ${REG_ACTIVE:-<unreadable>} active deployment(s), expected 6"
fi
if [[ "$REG_REVISION" =~ ^[0-9a-f]{64}$ ]]; then
  ok "registry revision ${REG_REVISION}"
else
  fail "registry revision '${REG_REVISION:-<unreadable>}' is not a 64-hex digest"
fi

# ── 2. the six tokens, each one checked against the expectation stated above ─
echo
log "issuer: the six canonical tokens"
COLOURS=""
for spec in $EXPECTED_TOKENS; do
  NAME="${spec%%:*}"
  REST="${spec#*:}"
  WANT_DEC="${REST%%:*}"
  WANT_PRIV="${REST#*:}"

  LINE="$(printf '%s\n' "$TOKEN_LINES" | grep "^ISSUER_TOKEN ${NAME} " | head -1 || true)"
  COUNT="$(printf '%s\n' "$TOKEN_LINES" | grep -c "^ISSUER_TOKEN ${NAME} " || true)"
  if [[ -z "$LINE" ]]; then
    fail "${NAME} is not in the registry"
    continue
  fi
  if [[ "$COUNT" != "1" ]]; then
    fail "${NAME} appears ${COUNT} times in the registry, expected once"
    continue
  fi
  GOT_ID="$(field "$LINE" id)"
  GOT_DEC="$(field "$LINE" decimals)"
  GOT_PRIV="$(field "$LINE" privacy)"
  GOT_ADDR="$(field "$LINE" address)"
  GOT_SYMBOL="$(field "$LINE" symbol)"
  GOT_REV="$(field "$LINE" sourceRevision)"

  BAD=""
  [[ "$GOT_ID" =~ ^[0-9a-f]{64}$ ]] || BAD="${BAD} id='${GOT_ID}' is not 64 hex"
  [[ "$GOT_DEC" == "$WANT_DEC" ]]   || BAD="${BAD} decimals=${GOT_DEC} want ${WANT_DEC}"
  [[ "$GOT_PRIV" == "$WANT_PRIV" ]] || BAD="${BAD} privacy=${GOT_PRIV} want ${WANT_PRIV}"
  [[ -n "$GOT_ADDR" ]]              || BAD="${BAD} no contract address"
  # The registry records the commit its verifier keys were compiled from, and the image was
  # built from exactly one commit. A mismatch means someone ran a deploy from a different
  # image against this registry.
  if [[ -n "${ISSUER_REF:-}" && "$GOT_REV" != "${ISSUER_REF}" ]]; then
    BAD="${BAD} sourceRevision=${GOT_REV} want ISSUER_REF ${ISSUER_REF}"
  fi
  if [[ -n "$BAD" ]]; then
    fail "${NAME}:${BAD}"
  else
    ok "${NAME} (${GOT_SYMBOL}) ${GOT_PRIV} ${GOT_DEC} dec  id ${GOT_ID}  at ${GOT_ADDR}"
  fi
  COLOURS="${COLOURS}${COLOURS:+,}${GOT_ID}"
done

# ── 3. the faucet site ──────────────────────────────────────────────────────
echo
log "issuer: the faucet site at ${FAUCET}"

CODE="$(httpcode "${FAUCET}/?network=undeployed")"
if [[ "$CODE" == "200" ]]; then
  ok "GET /?network=undeployed -> 200"
else
  fail "GET /?network=undeployed -> ${CODE}"
fi
# The SHELL, not merely a 200: `?network=` is a query string, so nginx serves index.html for it
# either way — what is asserted is that the page really is the SPA.
SHELL_BODY="$(curl -fsS --max-time 15 "${FAUCET}/?network=undeployed" 2>/dev/null || true)"
if printf '%s' "$SHELL_BODY" | grep -qi '<div id="root"' 2>/dev/null \
   || printf '%s' "$SHELL_BODY" | grep -q '/assets/' 2>/dev/null; then
  ok "the served page is the built SPA shell (it references its own /assets/ bundle)"
else
  fail "GET /?network=undeployed did not return the SPA shell"
fi

# THE REGISTRY, OVER HTTP, WITH ITS HEADERS. Headers and body in one request (`-D -`), so the
# two cannot come from different responses.
REG_HTTP="$(curl -fsS -D - --max-time 15 "${FAUCET}/metadata.undeployed.json" 2>/dev/null || true)"
REG_HEADERS="$(printf '%s' "$REG_HTTP" | sed -n '1,/^[[:space:]]*$/p' || true)"
REG_BODY="$(printf '%s' "$REG_HTTP" | sed -n '/^[[:space:]]*$/,$p' || true)"

CODE="$(httpcode "${FAUCET}/metadata.undeployed.json")"
if [[ "$CODE" == "200" ]]; then
  ok "GET /metadata.undeployed.json -> 200"
else
  fail "GET /metadata.undeployed.json -> ${CODE} (the registry is not being served)"
fi
# `grep -i` on the header block only. The SPA refuses a body whose content type does not
# contain `application/json`, so this is its own precondition, not a style check.
if printf '%s' "$REG_HEADERS" | grep -qi '^content-type:.*application/json' 2>/dev/null; then
  ok "the registry is served as application/json"
else
  fail "the registry's Content-Type is not application/json:"
  printf '%s' "$REG_HEADERS" | grep -i '^content-type:' | sed 's/^/      /' || true
fi
if printf '%s' "$REG_HEADERS" | grep -qi '^access-control-allow-origin:[[:space:]]*\*' 2>/dev/null; then
  ok "the registry carries Access-Control-Allow-Origin: *"
else
  fail "the registry does not carry Access-Control-Allow-Origin: * (upstream's _headers policy)"
fi
if printf '%s' "$REG_HEADERS" | grep -qi '^cache-control:.*max-age=300' 2>/dev/null; then
  ok "the registry carries Cache-Control: public, max-age=300, must-revalidate"
else
  fail "the registry's Cache-Control is not upstream's max-age=300 policy"
fi
# The BODY is the same registry the container validated, not some other file.
if [[ -n "$REG_REVISION" ]] && printf '%s' "$REG_BODY" | grep -qF -- "$REG_REVISION" 2>/dev/null; then
  ok "the served registry carries the same revision the validator read (${REG_REVISION:0:16}…)"
else
  fail "the served registry does not carry revision ${REG_REVISION:-<unreadable>}"
fi

# THE ZK LANE, as BYTES. One prover and one verifier, and the assertion is on the CONTENT TYPE
# and a non-empty body — an HTML shell would answer 200 too.
for artifact in contract/v1/shielded/keys/mint.verifier contract/v1/unshielded/keys/mint.prover; do
  ART_HDRS="$(curl -fsS -D - -o /dev/null --max-time 20 "${FAUCET}/${artifact}" 2>/dev/null || true)"
  ART_LEN="$(printf '%s' "$ART_HDRS" | sed -n 's/^[Cc]ontent-[Ll]ength:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1 || true)"
  if printf '%s' "$ART_HDRS" | grep -qi '^content-type:.*octet-stream' 2>/dev/null \
     && [[ -n "$ART_LEN" ]] && (( ART_LEN > 1000 )); then
    ok "/${artifact} is served as ${ART_LEN} bytes of application/octet-stream"
  else
    fail "/${artifact} is not served as binary bytes:"
    printf '%s' "$ART_HDRS" | grep -i '^content-\(type\|length\):' | sed 's/^/      /' || true
  fi
done
# A MISS MUST BE A MISS. Without `try_files … =404` the SPA fallback would answer 200 with
# index.html, and midnight-js would hand that HTML to the prover as a proving key.
CODE="$(httpcode "${FAUCET}/contract/v1/shielded/keys/there-is-no-such-circuit.prover")"
if [[ "$CODE" == "404" ]]; then
  ok "a missing ZK artifact is a real 404, not the app shell"
else
  fail "a missing ZK artifact answers ${CODE} — the SPA fallback is swallowing the artifact lane"
fi

# ── 4. THE FUNDING LANE — the assertion this profile exists for ─────────────
echo
FUND_TOKEN="${ISSUER_VERIFY_FUND_TOKEN:-TWBTC}"
FUND_AMOUNT="${ISSUER_VERIFY_FUND_AMOUNT:-100000000}"
FUND_SEED="${ISSUER_VERIFY_FUND_SEED:-0000000000000000000000000000000000000000000000000000000000000032}"
# `tail -c 4`, not `${var: -4}`: the negative-offset substring form is a bash-ism this
# repository does not rely on anywhere else, and the acceptance host is bash 3.2.
FUND_SEED_TAIL="$(printf '%s' "$FUND_SEED" | tail -c 4)"
log "issuer: minting ${FUND_AMOUNT} base units of ${FUND_TOKEN} to the wallet …${FUND_SEED_TAIL}"
info "(this is ISSUER_VERIFY_FUND_*; the coin stays in that wallet — see this script's header)"

FUND_RC=0
FUND_OUT="$(dc run --rm -T issuer-fund "$FUND_TOKEN" "$FUND_AMOUNT" "$FUND_SEED" 2>&1)" || FUND_RC=$?
printf '%s\n' "$FUND_OUT" | tail -20 | sed 's/^/      /'
FUND_LINE="$(printf '%s\n' "$FUND_OUT" | grep '^ISSUER_FUND_RESULT ' | head -1 || true)"
if (( FUND_RC != 0 )); then
  fail "issuer-fund exited ${FUND_RC}"
elif [[ -z "$FUND_LINE" ]]; then
  fail "issuer-fund exited 0 but printed no ISSUER_FUND_RESULT receipt"
else
  F_AMOUNT="$(field "$FUND_LINE" amount)"
  F_DELTA="$(field "$FUND_LINE" delta)"
  F_BEFORE="$(field "$FUND_LINE" balanceBefore)"
  F_AFTER="$(field "$FUND_LINE" balanceAfter)"
  F_VERIFIED="$(field "$FUND_LINE" verified)"
  F_TX="$(field "$FUND_LINE" tx)"
  F_ID="$(field "$FUND_LINE" tokenId)"

  # STRING equality on the amounts, never arithmetic. TWETH has 18 decimals, so one whole coin
  # is 10^18 base units — two orders of magnitude past what bash's 64-bit `(( ))` and
  # JavaScript's Number can represent exactly. Comparing the decimal strings is exact for
  # every token; comparing numbers is not.
  if [[ "$F_VERIFIED" != "true" ]]; then
    fail "the receipt says verified=${F_VERIFIED:-<unreadable>} — the balance was not read back"
  elif [[ "$F_DELTA" != "$FUND_AMOUNT" || "$F_AMOUNT" != "$FUND_AMOUNT" ]]; then
    fail "the recipient's balance moved by ${F_DELTA} (${F_BEFORE} -> ${F_AFTER}), not the ${FUND_AMOUNT} minted"
  else
    ok "${FUND_TOKEN}: ${F_BEFORE} -> ${F_AFTER}, delta EXACTLY ${F_DELTA} base units (tx ${F_TX})"
  fi
  # The receipt's colour must be the registry's colour for that name — otherwise the mint
  # landed, and landed in the wrong token.
  REG_ID_FOR_FUND="$(field "$(printf '%s\n' "$TOKEN_LINES" | grep "^ISSUER_TOKEN ${FUND_TOKEN} " | head -1 || true)" id)"
  if [[ -n "$REG_ID_FOR_FUND" && "$F_ID" == "$REG_ID_FOR_FUND" ]]; then
    ok "the minted colour is the registry's ${FUND_TOKEN} colour"
  else
    fail "the receipt's tokenId ${F_ID:-<unreadable>} is not the registry's ${REG_ID_FOR_FUND:-<unreadable>}"
  fi
fi

# ── 5. THE KERNEL REGISTRY — only when the offerfiles profile is up ─────────
echo
if service_present kernel; then
  log "issuer: the offer-files kernel's token registry"
  KNOWN="$(curl -fsS --max-time 15 "${KERNEL}/v1/known-tokens" 2>/dev/null || true)"
  if [[ -z "$KNOWN" ]]; then
    fail "GET ${KERNEL}/v1/known-tokens returned nothing"
  else
    for spec in $EXPECTED_TOKENS; do
      NAME="${spec%%:*}"
      REST="${spec#*:}"
      WANT_DEC="${REST%%:*}"
      WANT_PRIV="${REST#*:}"
      WANT_ID="$(field "$(printf '%s\n' "$TOKEN_LINES" | grep "^ISSUER_TOKEN ${NAME} " | head -1 || true)" id)"

      ROW="$(jrec "$KNOWN" "\"name\":\"${NAME}\"")"
      if [[ -z "$ROW" ]]; then
        fail "${NAME} is not in the kernel registry — did issuer-registrar run?"
        continue
      fi
      GOT_ID="$(jstr "$ROW" token_color)"
      GOT_DEC="$(jnum "$ROW" decimals)"
      GOT_KIND="$(jstr "$ROW" kind)"
      BAD=""
      [[ -n "$WANT_ID" && "$GOT_ID" == "$WANT_ID" ]] || BAD="${BAD} colour=${GOT_ID:-<none>} want ${WANT_ID:-<unreadable>}"
      [[ "$GOT_DEC" == "$WANT_DEC" ]]  || BAD="${BAD} decimals=${GOT_DEC:-<none>} want ${WANT_DEC}"
      [[ "$GOT_KIND" == "$WANT_PRIV" ]] || BAD="${BAD} kind=${GOT_KIND:-<none>} want ${WANT_PRIV}"
      if [[ -n "$BAD" ]]; then
        fail "kernel row ${NAME}:${BAD}"
      else
        ok "kernel row ${NAME} = ${GOT_ID} at ${GOT_DEC} decimals (${GOT_KIND})"
      fi
    done

    # ZERO PHANTOMS. The registrar's whole job is that these are gone; a stack where one
    # survives is a stack where a TW* quote is priced against a colour that does not exist.
    PHANTOM_FOUND=""
    for colour in $PHANTOM_COLOURS; do
      if printf '%s' "$KNOWN" | grep -qF -- "$colour" 2>/dev/null; then
        PHANTOM_FOUND="${PHANTOM_FOUND} ${colour:0:12}…"
      fi
    done
    if [[ -z "$PHANTOM_FOUND" ]]; then
      ok "zero Preprod phantom colours in the kernel registry (all six absent)"
    else
      fail "the kernel registry still holds Preprod phantom colour(s):${PHANTOM_FOUND}"
      info "  docker compose run --rm --no-deps issuer-registrar   # re-run the registrar"
    fi

    # THE CURRENT PIN'S OWN COLOURS MUST STILL BE THERE. Until phase C retires the kernel's
    # faucet contract, `offerfiles-deploy` still mints DEVA/DEVB/DEVU and
    # `offerfiles-token-names` still registers them — and the solver, the poster, the e2e
    # driver and the shielded-night book chain all still use them. An issuer that displaced
    # them would break every one of those in a way this section is the only place to notice.
    #
    # Asserted as a COUNT so that phase C, which retires those three names, sees a changed line
    # rather than a silent pass.
    DEV_PRESENT=0
    for dev in DEVA DEVB DEVU; do
      if printf '%s' "$KNOWN" | grep -qF "\"name\":\"${dev}\"" 2>/dev/null; then
        DEV_PRESENT=$(( DEV_PRESENT + 1 ))
      fi
    done
    if (( DEV_PRESENT == 3 )); then
      ok "the kernel pin's own DEVA/DEVB/DEVU rows are still present — the two token sets coexist"
    else
      fail "only ${DEV_PRESENT}/3 of DEVA/DEVB/DEVU are in the kernel registry; the issuer must not displace them at this kernel pin"
    fi

    # The registrar is IDEMPOTENT by the server's own semantics, and the cheapest proof of that
    # is to run it again: every UPDATE must report 0 rows and every POST the same-colour 409.
    log "issuer: re-running the registrar (it must change nothing)"
    RERUN_RC=0
    RERUN_OUT="$(dc run --rm --no-deps -T issuer-registrar 2>&1)" || RERUN_RC=$?
    printf '%s\n' "$RERUN_OUT" | grep -E 'ISSUER_REGISTRAR_RESULT|UPDATE [0-9]|POST [0-9]' | sed 's/^/      /' || true
    RERUN_LINE="$(printf '%s\n' "$RERUN_OUT" | grep 'ISSUER_REGISTRAR_RESULT ' | head -1 || true)"
    R_UPDATED="$(field "$RERUN_LINE" updated)"
    R_CREATED="$(field "$RERUN_LINE" created)"
    R_ALREADY="$(field "$RERUN_LINE" already)"
    if (( RERUN_RC != 0 )); then
      fail "the registrar's second run exited ${RERUN_RC}"
    elif [[ "$R_UPDATED" != "0" || "$R_CREATED" != "0" ]]; then
      fail "the registrar's second run changed something: updated=${R_UPDATED} created=${R_CREATED}"
    elif [[ "$R_ALREADY" != "6" ]]; then
      fail "the registrar's second run recognised ${R_ALREADY:-<unreadable>}/6 rows as already correct"
    else
      ok "the registrar is idempotent: updated=0 created=0 already=6 on the second run"
    fi
  fi
else
  info "the offerfiles profile is not up — skipping the kernel-registry checks"
  info "(the registry, the faucet and the funding lane above do not need a kernel; that is the"
  info " point of this profile depending only on core)"
fi

# ── 6. RESUME: a second issuer-deploy must deploy nothing ───────────────────
echo
log "issuer: re-running issuer-deploy (it must RESUME, not redeploy)"
RESUME_RC=0
RESUME_OUT="$(dc run --rm -T issuer-deploy 2>&1)" || RESUME_RC=$?
printf '%s\n' "$RESUME_OUT" | grep -E '\[resume\]|\[deploy\]|\[publish\]|ISSUER_DEPLOY_RESULT|marker' | sed 's/^/      /' || true
RESUME_COUNT="$(printf '%s\n' "$RESUME_OUT" | grep -c '^\[resume\] ' || true)"
REDEPLOY_COUNT="$(printf '%s\n' "$RESUME_OUT" | grep -c '^\[deploy\] ' || true)"
if (( RESUME_RC != 0 )); then
  fail "the second issuer-deploy exited ${RESUME_RC}"
else
  if [[ "$RESUME_COUNT" == "6" ]]; then
    ok "all six contracts were RESUMED and re-verified on chain (six [resume] lines)"
  else
    fail "the second run resumed ${RESUME_COUNT}/6 contracts"
  fi
  if [[ "$REDEPLOY_COUNT" == "0" ]]; then
    ok "nothing was redeployed (zero [deploy] lines)"
  else
    fail "the second run DEPLOYED ${REDEPLOY_COUNT} contract(s) — every coin already minted from the old ones is now orphaned"
  fi
fi

# The registry must be byte-identical afterwards, which is a stronger claim than "six resume
# lines": the runner rewrites the file on every successful run, and a rewrite that changed the
# revision would mean the deployment identities moved.
REGISTRY_AFTER="$(dc run --rm --no-deps -T issuer-registry 2>&1 | grep '^ISSUER_REGISTRY ' | head -1 || true)"
REV_AFTER="$(field "$REGISTRY_AFTER" revision)"
if [[ -n "$REG_REVISION" && "$REV_AFTER" == "$REG_REVISION" ]]; then
  ok "the registry revision is unchanged after the resume (${REV_AFTER:0:16}…)"
else
  fail "the registry revision changed across the resume: ${REG_REVISION:-<unreadable>} -> ${REV_AFTER:-<unreadable>}"
fi

# ── 7. OPT-IN: the pinned repository's own on-chain verification ────────────
if [[ "${ISSUER_VERIFY_ONCHAIN:-}" == "1" ]]; then
  echo
  log "issuer: ISSUER_VERIFY_ONCHAIN=1 — the pinned repository's own read-only verification"
  ONCHAIN_RC=0
  dc run --rm --no-deps -T -e ISSUER_VERIFY_ONCHAIN=1 issuer-registry || ONCHAIN_RC=$?
  if (( ONCHAIN_RC == 0 )); then
    ok "npm run verify:v1 re-verified all six contracts against chain state"
  else
    fail "npm run verify:v1 exited ${ONCHAIN_RC}"
  fi
fi

echo
if (( FAILURES == 0 )); then
  ok "issuer: all checks passed"
  exit 0
fi
err "issuer: ${FAILURES} check(s) failed"
exit 1
