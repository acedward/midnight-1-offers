#!/usr/bin/env bash
# price-feed — the daily CoinGecko refresh of `asset_prices`, alone, as PID 1.
#
# `exec bun run packages/price-feed/price-feed.dev.ts "$@"`, a single process.
#
# It is the ONLY process in this stack that talks to the public internet on purpose, and the
# only one that holds a secret (COINGECKO_API_KEY). It needs neither Midnight nor Celestia:
# it reads CoinGecko over HTTPS and writes `asset_prices` over the PostgreSQL wire. That is
# why this script waits on the DATABASE and on nothing else — no node block, no indexer, no
# proof server, no Celestia bridge. Compose still orders it after the kernel, but purely for
# the SCHEMA (see compose/prices.yml).
#
# ── THIS WRAPPER MUST NOT VALIDATE THE SERVICE'S OWN CONFIGURATION ──────────
# Upstream's entrypoint says so in capitals and it is load-bearing here too:
# `packages/price-feed/src/run.ts` decides what a missing key MEANS, and the two modes differ
# on purpose —
#     --once      prints one WARNING and exits 64 (EX_CONFIG)
#     loop mode   prints the same warning at start and on every tick, and IDLES
# A `require_env COINGECKO_API_KEY` here would turn that considered idle into a crash loop
# under `restart: unless-stopped`, printing one line forever, while the stack is perfectly
# usable on the prices 000-init.sql seeds. So the key is deliberately NOT required, NOT
# defaulted and NOT inspected by this file. It is never echoed either: the only thing any log
# in this repository ever says about it is the service's own `key=present` / `key=ABSENT`.
#
# ── WHY THE BLANK KNOBS ARE UNSET ───────────────────────────────────────────
# `loadPriceFeedConfig()` reads every knob with `ENV.getString(name, default)` /
# `ENV.getNumber(name, default)`, and both treat "" as a real value. Compose cannot express
# "leave this variable out" — `FOO: ${FOO:-}` with FOO absent renders as FOO="" — so an
# operator who simply left `PRICE_FEED_BATCH_SIZE` blank would override the code's 50 with an
# empty string. `unset_if_empty` (entrypoint-common.sh) is the repository's answer to that and
# every other entrypoint here uses it; COINGECKO_API_KEY is in the list because `""` and unset
# must mean the SAME thing for the key too (config.ts trims it and maps "" to null, so this is
# belt and braces rather than a behaviour change).
#
# ── ARGUMENTS ARE FORWARDED ─────────────────────────────────────────────────
# So the documented one-off works exactly as it does upstream:
#     docker compose run --rm --no-deps -T price-feed --once
# and the container exits with the run's own code — 0 every asset landed, 2 some did not,
# 64 no key / no schema. `scripts/verify-prices.sh` is built on precisely that.

# Consumed by log() in the sourced prelude, which shellcheck cannot see from here.
# shellcheck disable=SC2034
ROLE=price-feed
# shellcheck source=images/offerfiles-kernel/entrypoint-common.sh
. /usr/local/lib/offerfiles/entrypoint-common.sh

# The five DB variables are this service's whole launch contract, and it cannot sensibly
# default any of them: config.ts would fall back to 127.0.0.1/postgres/postgres, which inside
# a container means "nothing is there" plus a wrong role — a connection error naming the wrong
# component instead of the configuration error it is. DB_HOST/DB_PORT are additionally what
# THIS WRAPPER dials while waiting, which is the reason upstream requires exactly those two.
require_env DB_HOST DB_PORT DB_NAME DB_USER DB_PW

# Every optional knob, including the key: blank must reach the process as ABSENT.
unset_if_empty COINGECKO_API_KEY COINGECKO_BASE_URL PRICE_FEED_INTERVAL_MS \
               PRICE_FEED_REQUEST_SPACING_MS PRICE_FEED_BATCH_SIZE \
               PRICE_FEED_REQUEST_TIMEOUT_MS PRICE_FEED_ASSETS

# The schema this service writes into is applied by the KERNEL at startup, so waiting for the
# database socket is not enough on a first boot: the tables may not exist for a few more
# seconds. `run.ts` checks for `asset_prices` and `price_feed_status` explicitly and reports a
# clear message naming 000-init.sql, and in loop mode its retry ladder covers the gap — which
# is why this waits for the socket and then gets out of the way.
wait_tcp "${DB_HOST}" "${DB_PORT}" "database" "${DB_WAIT_TIMEOUT_S:-600}" \
  || die "the PostgreSQL socket at ${DB_HOST}:${DB_PORT} never answered"

cd "${REPO_ROOT}" || die "no ${REPO_ROOT}"
# `.dev.ts`, like every other service in this stack: "dev" names the target NETWORK, not the
# maturity of the code. For this process the network only ever reaches a log line anyway —
# DB_* decides where it writes and CoinGecko is the same endpoint on every network.
log "starting price-feed (packages/price-feed/price-feed.dev.ts) args: ${*:-<loop>}"
exec bun run packages/price-feed/price-feed.dev.ts "$@"
