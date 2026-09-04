#!/usr/bin/env bash
#
# Assertions for the `prices` profile — the `prices` section of ./verify.sh.
#
#   ./scripts/verify-prices.sh
#
# WHAT IT PROVES, and why each check is here rather than assumed:
#
#   the key         read off the RUNNING container's own environment, by EXIT CODE only
#                   (`test -n`) — the value is never read into this script, never echoed and
#                   never logged. With no key the section reports SKIPPED and asserts the
#                   documented IDLE behaviour instead (below); with a key it goes on.
#   a real refresh  `docker compose run --rm --no-deps price-feed --once` must exit 0. 0 means
#                   EVERY asset the cycle asked for landed; 2 means the cycle ran and some did
#                   not; 64 means no key or a database without the 00005 schema. Nothing softer
#                   would do: a service that is merely running proves nothing at all here,
#                   because its next scheduled cycle is up to 24 h away.
#   source: feed    all FIVE seeded assets (bitcoin, ethereum, usd-coin, midnight-3, usdm-2)
#                   read `source: feed` — the whole point of the profile. Before a refresh they
#                   read `seed`, which quotes correctly and is why the stack works without this
#                   profile at all, so `seed` here means the refresh did not land.
#   freshness       every asset's `updated_at` is within PRICES_VERIFY_MAX_AGE_S of now. This
#                   is what stops a `feed` row written days ago (or by another stack against a
#                   reused volume) from passing as "the refresh worked" — `source` alone is a
#                   sticky flag.
#   feed status     `feed.last_error` is null and `feed.last_ok_at` is fresh. Failures in this
#                   service are GRADED and non-fatal by design (one bad id fails one id; a 429
#                   stops the cycle keeping what it wrote), so the place a partial failure
#                   shows up is here — not in an exit code and not in a crash.
#   exactness       WBTC's and WETH's PER-BASE-UNIT price still equals their asset's COIN price
#                   divided by 10^decimals, EXACTLY, as decimal strings — now on FED values
#                   rather than the seeds verify-kernel.sh checks. This is the one assertion
#                   that could plausibly break on real data: the seeds are short decimals,
#                   CoinGecko's are not (e.g. 79518 vs 2455.89 vs 0.999818), and a rounding or
#                   float bug on the kernel's side would surface here first.
#   provenance      GET /v1/quote for the poster's WBTC -> WETH pair reports `from_source` and
#                   `to_source` both `feed`, a non-null `prices_updated_at`, and a
#                   `market_rate` that equals the two fed per-base-unit prices' ratio in the
#                   same double arithmetic the kernel uses. A refresh that moved `asset_prices`
#                   but not the quote path would be invisible everywhere else.
#
# WHAT IT DELIBERATELY DOES NOT PROVE. That the numbers are CORRECT — this stack has no second
# price oracle to compare against, and inventing one would be theatre. It proves the values are
# the provider's, are fresh, and are carried through the kernel's own arithmetic without loss.
# It also does not assert a particular price: BTC moves.
#
# ── THE ONE SIDE EFFECT THIS SCRIPT HAS ─────────────────────────────────────
# The `--once` cycle spends ONE CoinGecko request out of the demo plan's ~10 000 a month. That
# is the cost of proving the feature works, it is one request per ./verify.sh run, and it is
# recorded in docs/KNOWN-LIMITATIONS.md so nobody discovers it from a rate-limit error.
#
# ── THE KEY, AND WHY IT IS NEVER IN THIS FILE'S OUTPUT ──────────────────────
# COINGECKO_API_KEY is the only secret in this stack. This script learns exactly one bit about
# it — set or not — from the exit code of `test -n` run INSIDE the container, and prints only
# the words `present` or `ABSENT`. It never runs `docker inspect` over the container's Config
# (which would print the value), never echoes the variable, and never renders a compose config.
# The service itself has the same discipline: `describeConfig()` prints `key=present|ABSENT`.
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
# Every fragment, not just prices: `dc exec`/`dc run` must resolve the service, and naming one
# profile makes compose call every other profile's containers orphans on each invocation.
use_all_profiles

BIND="${HOST_ADDR:-127.0.0.1}"
API="http://${BIND}:${KERNEL_HOST_PORT:-9999}"

# How stale a refreshed price may be and still count as "this run refreshed it". Ten minutes:
# the `--once` above it finishes in seconds, so this is a ceiling with room for a slow provider
# and a slow prover box, not a wait.
MAX_AGE_S="${PRICES_VERIFY_MAX_AGE_S:-600}"

# The five ids ONE CYCLE REQUESTS when PRICE_FEED_ASSETS is blank — `SEEDED_ASSET_IDS` in the
# kernel's packages/database/price-map.ts, in its order. Stated here rather than derived
# because that list IS the expectation: an id silently dropped from a future kernel would
# otherwise make this section pass by asking about less.
SEEDED_ASSETS="bitcoin ethereum usd-coin midnight-3 usdm-2"

# The kernel's own default token-NAME → asset map (`DEFAULT_NAME_ASSET_MAP`, same file),
# one `<asset>:<NAME>[,<NAME>…]` word per asset.
#
# THIS IS NOT REDUNDANT WITH `known_tokens.asset_id`, AND ASSUMING IT WAS COST A GATE RUN.
# `asset_id` on a `known_tokens` row is an OVERRIDE, not the mapping: the seeded rows carry it
# (NIGHT/SNIGHT → midnight-3, USDC → usd-coin, USDM → usdm-2, all from 000-init.sql), but a
# colour registered through `POST /v1/known-tokens` — which is how WBTC and WETH get here,
# their colours being derived from the deployed contract address — leaves it **NULL**, and the
# kernel resolves those by NAME at read time. Measured on a live stack: rows 8 and 9 are
# `"name":"WBTC"/"WETH"` with `"asset_id":null`, while `GET /v1/prices` answers for both.
# So a colour lookup keyed on `asset_id` alone finds three of the five assets and misses
# exactly the two this section needs most.
#
# Precedence below mirrors the kernel's (API.md: "`known_tokens.asset_id` overrides the map"):
# an explicit `asset_id` wins, and the name map is the fallback.
ASSET_NAME_MAP="bitcoin:WBTC,WSBTC,BTC ethereum:WETH,WSETH,ETH usd-coin:USDC midnight-3:NIGHT,SNIGHT usdm-2:USDM"

FAILURES=0
fail() { err "$*"; FAILURES=$(( FAILURES + 1 )); }

# ── extractors, every one of them `|| true` ──────────────────────────────────

# jrec <json> <grep-ere> — the flattened JSON object matching <grep-ere>. `tr '{' '\n'` turns
# each object into a line; this is the idiom verify-kernel.sh already uses on the same
# endpoint, and it is enough because none of the objects read here nests another.
jrec() {
  printf '%s' "$1" | tr '{' '\n' | grep -E -- "$2" | head -1 || true
}
# jstr <record> <key> — a string field's value.
jstr() {
  printf '%s' "$1" | sed -n "s/.*\"$2\":\"\\([^\"]*\\)\".*/\\1/p" | head -1 || true
}
# jnum <record> <key> — an unquoted numeric field, integer or decimal, possibly negative.
# `[0-9][0-9]*`, never the GNU-only `[0-9]\+`: BSD sed silently matches nothing (00007 H2).
jnum() {
  printf '%s' "$1" | sed -n "s/.*\"$2\":\\(-\\{0,1\\}[0-9][0-9]*\\(\\.[0-9][0-9]*\\)\\{0,1\\}\\).*/\\1/p" | head -1 || true
}
# logs_count <service> <fixed-string> — how many log lines carry it.
logs_count() {
  dc logs --no-color "$1" 2>/dev/null | grep -c -F -- "$2" || true
}

# age_seconds <iso-8601> — seconds between that instant and now, computed in the price-feed
# container with `bun`.
#
# NOT on the host: `date -d` is GNU-only and `date -j -f` is BSD-only, and this repository runs
# its gates on Linux AND on a macOS acceptance box. The container is the one clock both hosts
# agree on, it is the same image the rest of this stack probes with `bun -e`, and it is the
# sentinel service this section already requires. Prints nothing when the timestamp cannot be
# parsed, which every caller treats as a failure rather than as age 0.
age_seconds() {
  local iso="$1"
  [[ -n "$iso" ]] || return 0
  # shellcheck disable=SC2016  # single quotes REQUIRED: process.argv is the container's, and
  # double quotes would have this shell expand the script text before bun ever saw it.
  dc exec -T price-feed bun -e '
    const t = Date.parse(process.argv[1]);
    if (!Number.isFinite(t)) process.exit(3);
    console.log(String(Math.round((Date.now() - t) / 1000)));
  ' "$iso" 2>/dev/null | tr -dc '0-9-' || true
}

log "prices: the feed"
info "kernel api  ${API}"
info "max age     ${MAX_AGE_S}s"

# ── is there a key? Read as ONE BIT, from the container, never printed ───────
#
# From the RUNNING container's environment rather than from this shell's: what matters is what
# the SERVICE was given, and compose is the only thing that knows that. `test -n` inside the
# container answers it through an exit code alone, so the value never crosses back.
#
# The entrypoint UNSETS a blank key before exec'ing the service, but `docker compose exec`
# starts a NEW process from the container's own configured environment — where compose's
# `${COINGECKO_API_KEY:-}` is present-and-empty when .env has no key. `test -n` reads that
# correctly in both directions.
KEY_PRESENT=0
# shellcheck disable=SC2016  # single quotes REQUIRED: the container's sh must expand this,
# not us — expanding it here would put the key on this script's command line.
if dc exec -T price-feed sh -c 'test -n "$COINGECKO_API_KEY"' >/dev/null 2>&1; then
  KEY_PRESENT=1
fi

# ── no key: assert the DOCUMENTED IDLE, then report the section SKIPPED ─────
#
# A missing key is a SUPPORTED configuration, not a broken one: 000-init.sql seeds real prices
# and every quote in the stack is already a real BTC/ETH ratio. So this must not fail. It must
# also not pass — the refresh this section exists to prove was never exercised — which is what
# SECTION_SKIP_RC and verify.sh's SKIPPED state are for (00011 B.5b: never let an untested
# section report success).
#
# It is not a BARE skip either. The three things the no-key path CLAIMS are cheap to check and
# are exactly what would break silently: the service stays up, it says so, and it is not
# crash-looping. Those are asserted; only the refresh is skipped.
if (( KEY_PRESENT == 0 )); then
  echo
  log "prices: no key — the documented idle"
  PF_CID="$(docker ps -aq \
    --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" \
    --filter "label=com.docker.compose.service=price-feed" 2>/dev/null | head -1 || true)"
  if [[ -z "$PF_CID" ]]; then
    fail "no price-feed container for project '${COMPOSE_PROJECT_NAME}' — verify.sh should not have reached this section"
  else
    PF_STATE="$(docker inspect -f '{{.State.Status}}' "$PF_CID" 2>/dev/null || true)"
    PF_RESTARTS="$(docker inspect -f '{{.RestartCount}}' "$PF_CID" 2>/dev/null || true)"
    if [[ "$PF_STATE" == "running" ]]; then
      ok "the price-feed container is running with no key (state=${PF_STATE})"
    else
      fail "the price-feed container is '${PF_STATE:-unreadable}', not running — with no key it must IDLE, not exit
            (packages/price-feed/src/run.ts returns 64 only for --once; loop mode warns and waits)"
    fi
    if [[ "$PF_RESTARTS" == "0" ]]; then
      ok "price-feed restart count is 0 — it is idling, not crash-looping"
    else
      fail "price-feed has restarted ${PF_RESTARTS:-?} time(s) — a missing key must NOT produce a restart loop
            (that is the whole reason loop mode warns instead of exiting; see compose/prices.yml)"
    fi
  fi
  # Its own words, both halves: the never-printed key field, and the warning that says what it
  # is going to do about it. A service that idled SILENTLY would be indistinguishable from one
  # quietly working, which is the confusion upstream's per-tick warning exists to remove.
  if [[ "$(logs_count price-feed 'key=ABSENT')" != "0" ]]; then
    ok "the service reports 'key=ABSENT' (and never the value — that is the only spelling it has)"
  else
    fail "the price-feed log does not carry 'key=ABSENT' — check 'docker compose logs price-feed'"
  fi
  if [[ "$(logs_count price-feed 'COINGECKO_API_KEY is not set')" != "0" ]]; then
    ok "the upstream missing-key WARNING is in the log"
  else
    fail "the price-feed log does not carry the missing-key warning
          (expected: '[price-feed] WARNING: COINGECKO_API_KEY is not set, so this service will do nothing…')"
  fi

  echo
  if (( FAILURES > 0 )); then
    err "prices: ${FAILURES} assertion(s) about the key-less idle failed"
    exit 1
  fi
  skip "no COINGECKO_API_KEY — the feed idles by design; set the key in .env to test the refresh"
  info "nothing about a REFRESH was asserted. Put a CoinGecko demo key in .env (see .env.example,"
  info "the 'price feed' block) and re-run; the seeded prices keep every quote correct meanwhile."
  exit "$SECTION_SKIP_RC"
fi

ok "the service has a key (present — this script never reads its value)"
# The LOOP container's own startup line, as corroboration that the key reached the service and
# not merely the `run` we are about to make.
if [[ "$(logs_count price-feed 'key=present')" != "0" ]]; then
  ok "the running service logged 'key=present' (never the value)"
else
  warn "the running price-feed container has not logged 'key=present' yet — it may have started before the key was set"
fi

# ── ONE REAL CYCLE ───────────────────────────────────────────────────────────
#
# `run --rm --no-deps`: a throwaway container, and `--no-deps` because postgres and the kernel
# are already up — without it compose would start (and leave) a second copy of the dependency
# chain. `--rm` is what keeps the teardown assertion clean.
#
# Exit code IS the result. 0 = every requested asset landed; 2 = the cycle ran and at least one
# did not; 64 = no key, no schema, or a cycle that threw. All three are reported here with the
# code, because "the feed didn't work" and "one CoinGecko id has gone away" want different
# fixes.
echo
log "prices: one refresh now (--once)"
ONCE_OUT="$(mktemp)"
trap 'rm -f "$ONCE_OUT"' EXIT
ONCE_RC=0
ONCE_T0=$SECONDS
dc run --rm --no-deps -T price-feed --once >"$ONCE_OUT" 2>&1 || ONCE_RC=$?
ONCE_S=$(( SECONDS - ONCE_T0 ))
if (( ONCE_RC == 0 )); then
  ok "'--once' exited 0 in ${ONCE_S}s — every requested asset was written"
else
  case "$ONCE_RC" in
    2)  fail "'--once' exited 2 after ${ONCE_S}s — the cycle ran but at least one asset did not land.
              GET /v1/prices 'feed.last_error' below says which; a 429 or one retired CoinGecko id
              both look like this." ;;
    64) fail "'--once' exited 64 after ${ONCE_S}s — misconfiguration: no usable key, or a database
              without the kernel's 000-init.sql schema (asset_prices / price_feed_status)." ;;
    *)  fail "'--once' exited ${ONCE_RC} after ${ONCE_S}s" ;;
  esac
  info "the cycle's own output follows:"
  sed 's/^/      /' "$ONCE_OUT" >&2 || true
fi
# The configuration line the service prints, asserted for the ONE property that matters here.
if grep -q -F -- 'key=present' "$ONCE_OUT"; then
  ok "the cycle's configuration line reads 'key=present' — the key is never printed, by design"
else
  fail "the cycle did not print 'key=present' (describeConfig() renders the key field as
        present|ABSENT and nothing else): $(head -c 300 "$ONCE_OUT" | tr '\n' ' ' || true)"
fi

# ── which colours cover the five assets ─────────────────────────────────────
#
# `GET /v1/prices` REQUIRES a `tokens=` list of 1-50 colours and answers with `assets[]`
# holding only the assets that EXPLAIN a requested colour — there is no unfiltered form. So to
# see all five assets, all five have to be asked for through a colour.
#
# Three of the five are seeded in known_tokens at fixed colours (NIGHT -> midnight-3,
# USDC -> usd-coin, USDM -> usdm-2). The other two are faucet presets whose colours DERIVE from
# the deployed contract address, so they cannot be seeded — WBTC -> bitcoin and
# WETH -> ethereum are registered by images/offerfiles-kernel/faucet-probe.ts, the same
# idempotent probe verify-kernel.sh uses. They are looked up BY ASSET rather than by name, so a
# stack that prices bitcoin under a different name still resolves.
echo
log "prices: the colours that cover all five assets"
KNOWN="$(curl -fsS --max-time 10 "$API/v1/known-tokens" 2>/dev/null || true)"
if [[ -z "$KNOWN" ]]; then
  fail "GET /v1/known-tokens did not answer — cannot map the five assets to colours"
fi
# The probe is only needed when the two derived presets are not registered yet: verify.sh runs
# the `kernel` section (which registers them) before this one, and the poster registers them at
# startup too — but this script must also work when run on its own.
#
# Tested BY NAME, not by asset_id: `POST /v1/known-tokens` leaves `asset_id` NULL and the
# kernel maps those rows by name (see ASSET_NAME_MAP above). An asset_id test here would arm
# the probe on every run — harmless, but it would also lie about why.
if [[ -n "$KNOWN" ]] && { ! printf '%s' "$KNOWN" | grep -q '"name":"WBTC"' \
                       || ! printf '%s' "$KNOWN" | grep -q '"name":"WETH"'; }; then
  info "WBTC/WETH are not registered yet — running the faucet probe to register them"
  KADDR="$(curl -fsS --max-time 10 "$API/v1/midnight/config" 2>/dev/null \
           | grep -oE '"contractAddress"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]+"' \
           | grep -oE '[0-9a-fA-F]{16,}' | head -1 || true)"
  if [[ -z "$KADDR" ]]; then
    fail "/v1/midnight/config carries no contract address, so the faucet presets cannot be derived"
  else
    # Mints nothing, holds no wallet, signs nothing: a derivation plus two idempotent registry
    # POSTs (409 on the second run is the normal answer).
    dc exec -T -e "FAUCET_PROBE_CONTRACT=${KADDR}" -e 'KERNEL_API_URL=http://127.0.0.1:9999' \
      kernel bun run /usr/local/lib/offerfiles/faucet-probe.ts >/dev/null 2>&1 || true
    KNOWN="$(curl -fsS --max-time 10 "$API/v1/known-tokens" 2>/dev/null || true)"
  fi
fi

# asset_names <asset> — the token NAMEs the kernel's default map points at that asset, one per
# line. Empty for an asset the map does not name (which would itself be a finding).
asset_names() {
  local want="$1" entry
  for entry in $ASSET_NAME_MAP; do
    if [[ "${entry%%:*}" == "$want" ]]; then
      printf '%s' "${entry#*:}" | tr ',' '\n'
      return 0
    fi
  done
  return 0
}

COLOURS=""
WBTC_COLOUR=""
WETH_COLOUR=""
for asset in $SEEDED_ASSETS; do
  # 1. an explicit `asset_id` on the row wins, exactly as it does in the kernel…
  ROW="$(jrec "$KNOWN" "\"asset_id\":\"${asset}\"")"
  HOW="asset_id"
  # 2. …and otherwise the row is found by one of the NAMEs the default map sends here.
  if [[ -z "$ROW" ]]; then
    while IFS= read -r cand; do
      [[ -n "$cand" ]] || continue
      ROW="$(jrec "$KNOWN" "\"name\":\"${cand}\"")"
      if [[ -n "$ROW" ]]; then
        HOW="name map"
        break
      fi
    done < <(asset_names "$asset")
  fi
  COLOUR="$(jstr "$ROW" 'token_color')"
  NAME="$(jstr "$ROW" 'name')"
  if [[ -z "$COLOUR" ]]; then
    fail "no registered colour maps to '${asset}', so this section cannot ask GET /v1/prices about it
          (the kernel seeds NIGHT/SNIGHT/USDC/USDM with an explicit asset_id, and the faucet probe
          registers WBTC/WETH by name — one of those did not happen)"
    continue
  fi
  info "${asset} <- ${NAME:-?} ${COLOUR:0:16}… (via ${HOW})"
  COLOURS="${COLOURS:+${COLOURS},}${COLOUR}"
  [[ "$asset" == "bitcoin" ]]  && WBTC_COLOUR="$COLOUR"
  [[ "$asset" == "ethereum" ]] && WETH_COLOUR="$COLOUR"
done

# ── every asset reads `feed`, and recently ──────────────────────────────────
echo
log "prices: source and freshness, all five assets"
PRICES=""
if [[ -z "$COLOURS" ]]; then
  fail "no colours resolved at all — GET /v1/prices cannot be asked anything"
else
  PRICES="$(curl -fsS --max-time 15 "$API/v1/prices?tokens=${COLOURS}" 2>/dev/null || true)"
  [[ -n "$PRICES" ]] || fail "GET /v1/prices?tokens=<five colours> did not answer"
fi

if [[ -n "$PRICES" ]]; then
  FED=0
  SEEN=0
  for asset in $SEEDED_ASSETS; do
    # `assets[]` rows carry asset_id but NOT token_color; the `tokens[]` rows carry both. The
    # -v is what tells the two apart, exactly as verify-kernel.sh does it.
    AREC="$(printf '%s' "$PRICES" | tr '{' '\n' | grep "\"asset_id\":\"${asset}\"" | grep -v '"token_color"' | head -1 || true)"
    if [[ -z "$AREC" ]]; then
      fail "GET /v1/prices has no assets[] row for '${asset}' even though a colour for it was requested"
      continue
    fi
    SEEN=$(( SEEN + 1 ))
    A_SOURCE="$(jstr "$AREC" 'source')"
    A_PRICE="$(jstr "$AREC" 'price_usd')"
    A_UPDATED="$(jstr "$AREC" 'updated_at')"
    if [[ "$A_SOURCE" == "feed" ]]; then
      FED=$(( FED + 1 ))
    else
      fail "'${asset}' reads source='${A_SOURCE:-none}', not 'feed' — the refresh did not reach this asset
            ('seed' is the 000-init.sql value: correct for quoting, but not a refresh)"
      continue
    fi
    A_AGE="$(age_seconds "$A_UPDATED")"
    if [[ -z "$A_AGE" ]]; then
      fail "could not read an age from '${asset}'s updated_at='${A_UPDATED:-none}'"
    elif (( A_AGE <= MAX_AGE_S )); then
      ok "${asset} = ${A_PRICE} USD/coin, source=feed, updated ${A_AGE}s ago"
    else
      fail "'${asset}' is source='feed' but its updated_at is ${A_AGE}s old (ceiling ${MAX_AGE_S}s)
            — 'feed' is a sticky flag, so this is a stale row from an earlier run or a reused volume,
            not the refresh this section just made"
    fi
  done
  if (( SEEN == 5 && FED == 5 )); then
    ok "all five seeded assets read source=feed with a fresh updated_at"
  fi

  # ── the feed's own last-cycle record ──────────────────────────────────────
  # Where a GRADED failure lands: one bad id fails one id, a failed request is recorded against
  # every id it carried, and a 429 stops the cycle keeping what it wrote. None of those is an
  # exit code and none is a crash, so `last_error` is the only place they are visible.
  echo
  log "prices: the feed's own status"
  FREC="$(jrec "$PRICES" '"provider"')"
  if [[ -z "$FREC" ]]; then
    fail "GET /v1/prices carries no feed{} block: ${PRICES:0:300}"
  else
    F_PROVIDER="$(jstr "$FREC" 'provider')"
    F_LAST_OK="$(jstr "$FREC" 'last_ok_at')"
    case "$FREC" in
      *'"last_error":null'*)
        ok "feed.last_error is null" ;;
      *)
        fail "feed.last_error is not null: $(jstr "$FREC" 'last_error')" ;;
    esac
    if [[ "$F_PROVIDER" == "coingecko" ]]; then
      ok "feed.provider is 'coingecko'"
    else
      fail "feed.provider is '${F_PROVIDER:-none}', expected 'coingecko'"
    fi
    F_AGE="$(age_seconds "$F_LAST_OK")"
    if [[ -z "$F_AGE" ]]; then
      fail "feed.last_ok_at is '${F_LAST_OK:-null}' — the feed has never completed a cycle against this database"
    elif (( F_AGE <= MAX_AGE_S )); then
      ok "feed.last_ok_at is ${F_AGE}s old (${F_LAST_OK})"
    else
      fail "feed.last_ok_at is ${F_AGE}s old (ceiling ${MAX_AGE_S}s): ${F_LAST_OK}"
    fi
  fi

  # ── per-base-unit == coin / 10^decimals, EXACTLY, on FED values ──────────
  # verify-kernel.sh proves this on the SEEDS, which are short decimals chosen by hand. These
  # are the provider's: five and six significant figures, sub-cent stablecoins, and a coin
  # price that moves between runs. If the kernel's decimal handling has a rounding or float
  # bug, this is where it shows.
  echo
  log "prices: per-base-unit exactness on fed values"
  # COLON-DELIMITED, NOT a `read` over a here-doc, and that is a bug this section was written
  # with and then measured out of it. With `read -r P_NAME P_COLOUR P_ASSET` over
  # `WBTC ${WBTC_COLOUR} bitcoin`, an EMPTY colour makes default IFS collapse the double space
  # and every field shifts left — P_COLOUR becomes "bitcoin" and the row is looked up under a
  # colour that cannot exist, so the failure blames the wrong thing. The empty-state harness
  # (00011 C.8's rule) caught it before the live gate; a `for` over one word per preset cannot
  # have the problem at all. A missing colour has already been reported by name in the
  # colour-resolution block above, so here it is skipped rather than re-failed.
  for P_SPEC in "WBTC:${WBTC_COLOUR}:bitcoin" "WETH:${WETH_COLOUR}:ethereum"; do
    P_NAME="${P_SPEC%%:*}"
    P_REST="${P_SPEC#*:}"
    P_COLOUR="${P_REST%%:*}"
    P_ASSET="${P_REST#*:}"
    if [[ -z "$P_COLOUR" ]]; then
      info "${P_NAME} has no registered colour on this stack — its exactness rule cannot be checked here"
      continue
    fi
    T_ROW="$(jrec "$PRICES" "\"token_color\":\"${P_COLOUR}\"")"
    A_ROW="$(printf '%s' "$PRICES" | tr '{' '\n' | grep "\"asset_id\":\"${P_ASSET}\"" | grep -v '"token_color"' | head -1 || true)"
    if [[ -z "$T_ROW" || -z "$A_ROW" ]]; then
      fail "GET /v1/prices is missing the tokens[] or assets[] row for ${P_NAME}/${P_ASSET}"
      continue
    fi
    T_SOURCE="$(jstr "$T_ROW" 'source')"
    T_DEC="$(jnum "$T_ROW" 'decimals')"
    T_UNIT="$(jstr "$T_ROW" 'price_usd')"
    A_COIN="$(jstr "$A_ROW" 'price_usd')"
    if [[ "$T_SOURCE" != "feed" ]]; then
      fail "${P_NAME}'s tokens[] row reads source='${T_SOURCE:-none}', not 'feed'"
      continue
    fi
    if [[ -z "$T_DEC" || -z "$T_UNIT" || -z "$A_COIN" ]]; then
      fail "could not read ${P_NAME}'s decimals/per-base-unit/coin price: ${T_ROW:0:200}"
      continue
    fi
    T_EXPECTED="$(decimal_shift_left "$A_COIN" "$T_DEC")"
    if [[ "$T_UNIT" == "$T_EXPECTED" ]]; then
      ok "${P_NAME} per base unit is ${T_UNIT} == ${A_COIN} / 10^${T_DEC}, exactly (source=feed)"
    else
      fail "${P_NAME}'s per-base-unit price is ${T_UNIT}, expected ${A_COIN} / 10^${T_DEC} = ${T_EXPECTED} exactly"
    fi
  done
fi

# ── the quote path carries the refresh ──────────────────────────────────────
#
# `asset_prices` is not what a caller reads: `GET /v1/quote` is, and it goes through
# `token_prices`. A refresh that landed in one and not the other would be invisible in the
# section above and would show up as "the SPA still quotes yesterday's rate".
#
# The pair is the poster's own WBTC -> WETH, which is what the SPA's Market view and
# verify-poster.sh's sponsorship assertion both use.
echo
log "prices: quote provenance (WBTC -> WETH)"
if [[ -z "$WBTC_COLOUR" || -z "$WETH_COLOUR" ]]; then
  fail "no WBTC/WETH colours resolved, so the quote's provenance cannot be checked"
else
  QUOTE="$(curl -fsS --max-time 15 \
    "$API/v1/quote?from_token=${WBTC_COLOUR}&to_token=${WETH_COLOUR}&from_amount=1000000" \
    2>/dev/null || true)"
  if [[ -z "$QUOTE" ]]; then
    fail "GET /v1/quote for WBTC -> WETH did not answer"
  else
    Q_FROM="$(jstr "$QUOTE" 'from_source')"
    Q_TO="$(jstr "$QUOTE" 'to_source')"
    Q_RATE="$(jnum "$QUOTE" 'market_rate')"
    Q_SUGGEST="$(jstr "$QUOTE" 'suggested_to_amount')"
    Q_UPDATED="$(jstr "$QUOTE" 'prices_updated_at')"
    if [[ "$Q_FROM" == "feed" && "$Q_TO" == "feed" ]]; then
      ok "both legs carry feed provenance (from_source=${Q_FROM} to_source=${Q_TO})"
    else
      fail "quote provenance is from_source='${Q_FROM:-none}' to_source='${Q_TO:-none}', expected feed on both
            — asset_prices was refreshed but the quote path did not follow"
    fi
    Q_AGE="$(age_seconds "$Q_UPDATED")"
    if [[ -z "$Q_AGE" ]]; then
      fail "quote prices_updated_at is '${Q_UPDATED:-null}' — it is null when either leg is demo-fallback"
    elif (( Q_AGE <= MAX_AGE_S )); then
      ok "quote prices_updated_at is ${Q_AGE}s old (the OLDER of the two legs)"
    else
      fail "quote prices_updated_at is ${Q_AGE}s old (ceiling ${MAX_AGE_S}s): ${Q_UPDATED}"
    fi
    # market_rate against the two fed per-base-unit prices. Done in the container's JS — the
    # same double arithmetic the kernel used to produce the number — because bash has no float
    # arithmetic and a bash-side integer comparison of a ratio would be meaningless. The
    # tolerance is relative and tiny: this asserts "the kernel divided the two prices this
    # refresh wrote", not an independently computed rate.
    W_UNIT="$(jstr "$(jrec "$PRICES" "\"token_color\":\"${WBTC_COLOUR}\"")" 'price_usd')"
    E_UNIT="$(jstr "$(jrec "$PRICES" "\"token_color\":\"${WETH_COLOUR}\"")" 'price_usd')"
    if [[ -z "$W_UNIT" || -z "$E_UNIT" || -z "$Q_RATE" ]]; then
      fail "cannot cross-check market_rate: wbtc='${W_UNIT:-none}' weth='${E_UNIT:-none}' market_rate='${Q_RATE:-none}'"
    else
      # shellcheck disable=SC2016  # single quotes REQUIRED: process.argv is the container's.
      RATE_CHECK="$(dc exec -T price-feed bun -e '
        const [w, e, mr] = process.argv.slice(1).map(Number);
        const expected = w / e;
        const ok = Math.abs(mr - expected) <= 1e-9 * Math.max(1, Math.abs(expected));
        console.log((ok ? "OK " : "BAD ") + expected);
      ' "$W_UNIT" "$E_UNIT" "$Q_RATE" 2>/dev/null || true)"
      case "$RATE_CHECK" in
        OK*)  ok "market_rate ${Q_RATE} == fed WBTC ${W_UNIT} / fed WETH ${E_UNIT} (${RATE_CHECK#OK }); 1 WBTC quotes ${Q_SUGGEST} WETH base units" ;;
        BAD*) fail "market_rate is ${Q_RATE} but the two fed prices give ${RATE_CHECK#BAD } (${W_UNIT} / ${E_UNIT})" ;;
        *)    fail "could not compute the expected market_rate inside the price-feed container" ;;
      esac
    fi
  fi
fi

echo
if (( FAILURES == 0 )); then
  ok "prices: all checks passed"
  exit 0
fi
err "prices: ${FAILURES} check(s) failed"
exit 1
