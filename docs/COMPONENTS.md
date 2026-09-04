# Components

> **Scope.** This file documents the source pins that decide which LINE the stack runs, the
> **`solver`** profile's own processes, the **`poster`** profile, the **`prices`** profile and
> the **`shielded-night`** profile. The component notes for `core`, `offerfiles` and `frontend`
> are still to be written; `README.md` remains the map of the stack.

## Source pins, and the line they put this stack on

Every external identity lives in `config/artifact-decisions.json`; these are the two that decide
what the stack *means* rather than merely which bytes it runs.

| Pin | Value | Line |
|---|---|---|
| `KERNEL_REF` | `c293ebd57937c0065663b08b2c244438be8989a5` — `effectstream/zswap-offerfiles-kernel` `main` | ledger-v8 / 1.x, **the whole-coin line** (kernel #61/#63/#66) |
| `FRONTEND_REF` | `58ab921be5513b77937a37be86bf724a41888302` — `effectstream/effectstream` `midnight-1`, subtree `templates/zswap-da` @ `3ca1d56ffc29f03c73cf43432bdfeeaf3ab43c6b` | the same line's UI (effectstream#918) |
| `SHIELDED_NIGHT_REF` | `f7fcefa7921bf2c3f634871f9ad3aa3a32251af0` — `effectstream/shielded-night` `main` | unchanged |

**There is no solver pin.** Since 00011 PR B `images/cow-solver` is `FROM kernel-image` plus four
entrypoints, so the solver, its monitor and its two one-shots are all *the kernel commit above*.
`SOLVER_REPO`/`SOLVER_REF` are retired — set, they now only produce a warning from
`scripts/lib/common.sh`. See "The solver IS the kernel commit" below.

### The whole-coin line (kernel #63 + effectstream#918)

These two are **one change across two repositories** and must always move together. Before them,
`known_tokens.decimals` defaulted to `0` and a faucet press minted 1 000 *base units*, which the
registry called 1 000 coins. Since them:

* `known_tokens.decimals` **DEFAULTS to 6**, and every seeded row (NIGHT, SNIGHT, USDC, USDM) is
  6. Every registration path in and around this repository sends `decimals: 6` **explicitly**
  anyway — `images/offerfiles-kernel/entrypoint-token-names.sh` for DEVA/DEVB/DEVU,
  `images/shielded-night/entrypoint-token-name.sh` for sNight, the SPA for anything minted from
  the faucet — because a kernel pinned before #63 would otherwise silently record `0`.
* one faucet press is **1 000 whole coins = `1000000000` base units**. The number is defined once,
  upstream, in `docs/src/wallet/mintable.ts` (`MINT_COINS` / `MINT_AMOUNT`), which the SPA faucet,
  `deploy/scripts/lib/faucet-mint.ts` and the offer poster all import.
* prices are served **per base unit**: `asset_prices.price_usd / 10^decimals`. With the seeded
  coin prices at this pin, `WBTC` is `77387 / 10^6 = 0.077387` and `WETH`
  `2393.28 / 10^6 = 0.00239328`, exactly.
* the SPA reads each token's `decimals` off `GET /v1/known-tokens` and scales everything it shows
  and submits by `10^decimals`, so the faucet says `1,000` and a take moves a balance by exactly
  the coins displayed.

`./verify.sh`'s `kernel` section asserts all of this — see the `token decimals` and `faucet`
blocks in `scripts/verify-kernel.sh`, and `images/offerfiles-kernel/faucet-probe.ts`, which reads
the allotment out of the RUNNING image's own tree rather than re-declaring it here.

**Moving an EXISTING stack onto this line is BREAKING for its `postgres` volume**, silently — see
`docs/OPERATIONS.md`. `./down.sh -v` is the upgrade path.

## The `solver` profile — the COW solver, its status listener and its monitor

### The solver IS the kernel commit

`images/cow-solver` used to be an **overlay**: it fetched a second commit (`SOLVER_REF`) and
`COPY`d that tree over the locally built kernel image. That was sound only while the solver
lived on a branch *descended* from the kernel pin. Kernel PR #48 merged the whole solver line
into `main` and inverted the relationship, with two results:

* a `COPY` **merges**, so overlaying an ancestor **reverted 25 solver files** to their
  pre-#53/#58 state while leaving the 7 files added after it in place — a mixed tree whose
  executable code was the old PR #52 solver, without #53's capital-free fee sizing and without
  #58's status listener;
* at `KERNEL_REF=c293ebd…` it stopped building at all, because the base image carries workspace
  packages (`packages/solver-frontend`, the poster's `deploy/scripts/lib/poster-*.ts`) that the
  old `bun.lock` has never seen and the image's `bun install --frozen-lockfile` refuses.

The image is now `FROM kernel-image` and adds only entrypoints. One consequence is worth
stating plainly: **every process in this stack built from the kernel repository reports the same
commit**, and `/app/.solver-commit` no longer exists anywhere. `scripts/verify-source-pins.sh`
asserts both — the solver image's `/app/.kernel-commit == KERNEL_REF`, and the *absence* of the
retired second commit file.

| Container | Entrypoint | What it is |
|---|---|---|
| `solver` | `entrypoint-solver.sh` | the posted-price solver in EXECUTION mode (`start.solver.ts`) |
| `solver-frontend` | `entrypoint-solver-frontend.sh` | the read-only monitor site (`start.solver-frontend.ts`) |
| `solver-provision` | `entrypoint-solver-provision.sh` | one-shot: the solver's trading inventory |
| `maker-offer` | `entrypoint-maker-offer.sh` | one-shot: one real, settle-able offer on the book |

### The read-only status listener (`:9100`)

The solver serves its own state on a second listener, **opt-in by the port and by nothing else**:
with `SOLVER_STATUS_PORT` unset the solver behaves exactly as it did before. Set, it serves

| Route | Auth | Body |
|---|---|---|
| `GET /health` | none | `{status, ready, mode, contractVersion}` — nothing internal, so a container healthcheck needs no secret |
| `GET /status/snapshot` | **bearer** | the versioned `StatusSnapshot`: process, backend, book, inventory, relay, ladder, executor, journal, admission, listener |
| `GET /status/stream` | **bearer** | the same as SSE, one frame on connect then on change; the solver closes each stream after five minutes so its client cap can self-heal |

Collection reads **in-memory state only** — no wallet call, no proof, no kernel or relay I/O —
and no route mutates anything.

`SOLVER_STATUS_AUTH_TOKEN` is **mandatory and ≥ 32 characters** whenever the port is set: a
missing or short value is one of the problems `start.solver.ts` lists *before it binds*, not a
late 401. `/status/*` carries the solver's entire internal state, so the listener must never be
able to come up open. m1 commits a devnet default (like the relay bearer) so `./up.sh` works with
no `.env`, and `scripts/pick-ports.sh` emits a random 64-hex value into every generated one.

**The port is not published on the host**, deliberately. The monitor is its reader, over the
compose network; `compose/solver.yml` carries a commented `SOLVER_STATUS_HOST_PORT` block for a
debugging session, and reading the raw JSON needs nothing published anyway:

```bash
docker compose exec solver bun -e 'const r = await fetch(
  "http://127.0.0.1:9100/status/snapshot",
  { headers: { authorization: "Bearer " + process.env.SOLVER_STATUS_AUTH_TOKEN } });
  console.log(await r.text());'
```

### The monitor (`solver-frontend`, `:${SOLVER_FRONTEND_HOST_PORT}`)

One Bun process, no build step, no database, and **no route that writes anything** — here or
upstream. It answers one question at a glance: *is the solver quoting, and if not, why*.

| Block | Read from |
|---|---|
| Status pill — QUOTING / WITHDRAWN / DISCONNECTED / STARTING / DRY-RUN / SOLVER UNREACHABLE | the solver snapshot |
| Health strip — six stages: kernel sync → book cache → inventory → journal & DUST → relay socket → published ladder | kernel `/v1/health/sync` + the snapshot |
| Alarms, tiles, published ladders (with the maker hash per rung), *not published* with the solver's own exclusion reason, book, jobs, inventory, DUST, relay, configuration, events | as labelled in each block's `?` |

Its own surface is `GET /`, five named static files, `/api/snapshot`, `/api/stream` and
`/health`; everything else is 404, and a write method on a known route is 405.

**It depends on the KERNEL only — never on the solver.** The moment anyone actually opens it is
the moment the solver is down, so an unreachable solver is a *rendered state* ("SOLVER
UNREACHABLE", with the time it was last seen) beside a live book and sync panel, and never a
reason to refuse to start. Its `/health` is the site's own liveness and says nothing about the
solver: a monitor whose health followed the thing it monitors would restart itself exactly when
it is needed.

**It has no authentication of its own**, which is why its host port binds `BIND_ADDR`
(127.0.0.1) like everything else here. Put a reverse proxy in front of it before it reaches any
wider network — and note that the SSE feed needs response buffering off and a read timeout
longer than the five-minute stream lifetime.

Two things it is careful about, and `./verify.sh` asserts both:

* **an empty ladder is never shown as "no liquidity"** — when the solver's push carries a
  `withheld` reason the page says which one (`cache-not-current` is the fail-closed withdrawal,
  `withdrawn` a deliberate one);
* **amounts are integer base units everywhere**; a coin-denominated value is shown *beside* them
  and marked as derived, using the kernel registry's `decimals` (6 on the whole-coin line).

## The `poster` profile — the offer poster, so the book supplies itself

### What it is

`deploy/scripts/offer-poster.ts` at the pinned kernel commit, run by this repository's own
`entrypoint-offer-poster.sh`. It is the kernel repository's own service and this repository's
own entrypoint — the same relationship the solver, the batcher and the deploy one-shot already
have — so it carries ONE commit identity with everything else built from that tree
(`/app/.kernel-commit`).

Every `POST_INTERVAL_MS` (60 s by default) exactly one of two things happens:

* **re-offer** — a coin the journal already owns has come back (its last offer is `expired` or
  `cancelled` in the kernel **and** its nonce is visible again in the wallet's
  `availableCoins`), so the tick posts a fresh offer for that exact coin at today's quote;
* **mint** — no coin is free, so the tick calls the faucet circuit
  `mint_shielded(domainSep(GIVE_TOKEN), GIVE_AMOUNT, freshNonce)` — paying the mint fee from
  its **own DUST** — waits for the coin to appear, and offers it.

Either way the offer **spends its coin whole**: there is no change output, so every offer on
the book is a complete, independent swap rather than a slice of a shared balance. The want leg
is not a knob by default — it is `suggested_to_amount` from the kernel's `GET /v1/quote` for
that coin's actual value, which lands the offer exactly on the sponsorship threshold so the
batcher pays its Celestia fee.

### The two services

| service | shape | what it is for |
|---|---|---|
| `poster-provision` | one-shot, `restart: "no"`, idempotent through a marker on the `poster-state` volume | four UTXOs of `5_000_000_000_000` NIGHT from genesis-1 to the poster's dedicated wallet, under the genesis-1 `flock`. **NIGHT and nothing else**: the poster registers it for DUST itself at startup. A few LARGE UTXOs rather than many small ones, because a dust coin's capacity is tied to the size of the NIGHT UTXO backing it. |
| `offer-poster` | the LOOP, `restart: unless-stopped`, `/health` on `:9977` (published as `${POSTER_HEALTH_HOST_PORT}`) | the poster itself. No marker: a marker on a loop would make a restart a permanent no-op. Idempotence lives in the JOURNAL instead. |

### The exact-coin guarantee

The wallet SDK's default coin selector is smallest-first and cannot be told which coin to
spend. The poster therefore builds its own facade with a **pinned selector**
(`deploy/scripts/lib/pinned-wallet.ts`): while a nonce is armed, the selector returns that coin
for the give colour or **nothing at all** — never a substitute. After `finalizeTransaction` the
tick asserts the built transaction's input nullifiers equal `[the pinned coin's nullifier]` and
that the fallible section has no inputs; if they differ the recipe is **reverted** and nothing
is posted.

`./verify.sh`'s `poster` section checks that from OUTSIDE, by comparing two independent
records: the journal's own `nullifier` for the coin, and the kernel's
`computed.inputNullifiers` for the offer built from it. One entry, equal.

### The journal

`/var/lib/offer-poster/journal.json`, on the `poster-state` volume: one entry per coin the
poster has ever minted — the coin identity (`type`, `nonce`, `value`, `nullifier`), the mint
transaction, and every offer built from it with its quote snapshot and last known kernel
status. Written atomically and **before** a mint is submitted, so a poster killed between
minting and posting finds the orphan on restart and re-offers it rather than leaking a coin.

It is **keyed by the contract address**, and refuses to open against a different one rather
than merging — those coins do not exist on this chain. That is also why the journal volume is
in the `./down.sh -v` wipe group with everything else.

### Its wallet, and the genesis-1 mutex

`OFFER_POSTER_SEED` is a DEDICATED roster seed (`…0041`, `wallets/wallets.json`). The poster is
a long-lived facade like the batcher and the solver, and it is the one facade that **enforces**
the one-seed rule on itself: `poster-config.ts` exits 78 if its seed matches any of the seven
seed variables it can see in its own environment. That is why `compose/poster.yml` spells the
Midnight endpoints out on the `offer-poster` service instead of reusing an anchor — upstream's
anchor carries `MIDNIGHT_WALLET_SEED`.

`poster-provision` drives **genesis-1**, and so do `solver-provision` and `maker-offer` in
`compose/solver.yml`. A `depends_on` cannot serialise across fragments (compose will not render
a dependency on a service outside the merged set, and `--with poster` without `--with solver`
is supported), so all three take a `flock` on a file on a shared `genesis-lock` volume that
both fragments declare identically. See `take_genesis_lock()` in
`images/offerfiles-kernel/entrypoint-common.sh`.

### Why it is not part of `offerfiles` or `solver`

It mints continuously and needs a funded wallet, so it is opt-in — exactly as the kernel
repository ships it (`docker compose --profile poster up`). It also needs neither the relay nor
the solver, and putting it in `solver` would have coupled a book-filling service to the private
relay clone that profile requires.

## The `prices` profile — the price feed, so the reference is live

### What it is

`packages/price-feed` in the kernel repository: one long-running process that refreshes
`asset_prices`, the USD reference table behind `GET /v1/prices`, `GET /v1/quote`'s
`market_rate` and the batcher's fee-sponsorship gate. It is the kernel's own service, run here
on the kernel image with one more entrypoint — `entrypoint-price-feed.sh` — exactly as the
poster and the solver are.

It is the **only process in this stack that talks to the public internet on purpose**, and the
only one that holds a secret. It needs neither Midnight nor Celestia: it reads CoinGecko over
HTTPS and writes PostgreSQL, which is why its entrypoint waits on the database and on nothing
else.

It also **holds no wallet and has no seed** — the only service here other than the frontend and
the monitor that does not, so it appears in none of `docs/WALLETS.md`'s tables and takes no part
in the genesis-1 facade mutex.

### What it refreshes, and what `source` means

One cycle asks CoinGecko `simple/price` for the **five seeded asset ids**, batched into as few
requests as `PRICE_FEED_BATCH_SIZE` (default 50) allows — so today's five are **one request**:

| asset id | what it prices here |
|---|---|
| `bitcoin` | `WBTC` / `WSBTC` / `BTC` — the faucet's BTC-priced presets |
| `ethereum` | `WETH` / `WSETH` / `ETH` |
| `usd-coin` | `USDC` |
| `midnight-3` | `NIGHT`, and `SNIGHT` — the shielded-night wrapper is locked 1:1 against NIGHT, so it is the same asset and needs no second price |
| `usdm-2` | `USDM` — Moneta's Cardano USDM, the asset the VIA Labs bridge carries to Midnight. It trades AROUND a dollar but is not a dollar, so it is observed like the rest: USD is the numeraire and nothing is pinned to it, which is what makes a depeg visible in the quotes |

Tokens map to assets **by NAME**, not by colour: faucet colours derive from the contract
address and change on every clean redeploy, so a colour-keyed map would be stale on every
`./down.sh -v`. `known_tokens.asset_id` overrides the map and `PRICE_FEED_MAP` overrides the
defaults — note that `PRICE_FEED_MAP` is a **kernel/batcher** knob (they read it), not a
price-feed one, which is why it lives with the sponsorship settings in `.env.example` and not
in this profile's block.

Every price row carries a `source`, and the whole point of this profile is which one:

| `source` | meaning |
|---|---|
| `seed` | the value shipped in `000-init.sql`, captured 2026-09-02. **A stack that never runs this profile still quotes real ratios** — that is why it is opt-in |
| `feed` | fetched from CoinGecko by this service |
| `manual` | an operator's row in `token_prices`. Wins over everything; nothing rewrites it |
| `fallback` | the deterministic demo price derived from the token's colour. **Not a market price**, and the sponsorship gate treats it as *unpriced* |

After a refresh, `GET /v1/prices` reports `source: feed` with a fresh `updated_at`, and
`GET /v1/quote` follows on both legs (`from_source` / `to_source` / `prices_updated_at` — the
older of the two legs, because a quote is only as fresh as its stalest side). Prices are served
**per base unit**: a token's price is its asset's coin price divided by `10^decimals`, and since
every token here is 6 decimals, `WBTC` at $79 518 a coin is `0.079518` per base unit.

### The key, and the four rules around it

`COINGECKO_API_KEY` is the only secret in this stack. Every other credential here is a public
devnet placeholder.

1. **`.env` and nowhere else.** There is deliberately **no compose default** for it, it is
   never baked into an image, never put on a command line, and never committed — `.gitignore`
   covers `.env` and `.env.*` and re-includes only `.env.example`, which carries the name with
   an empty value.
2. **Header, never a query string.** `packages/price-feed/src/coingecko.ts` sends it as
   `x-cg-demo-api-key`. A query parameter would put it in every access, proxy and
   browser-devtools log.
3. **Never printed.** The service renders its whole effective configuration at startup with the
   key's field as the literal `key=present` or `key=ABSENT`. Nothing in this repository prints
   more than that either: `scripts/verify-prices.sh` learns whether a key exists from the *exit
   code* of `test -n` run inside the container, so the value never crosses back into a script.
4. **Never in a rendered compose config.** `docker compose config` interpolates it, so never
   render one with your real `.env` into a log or a paste. `scripts/verify-compose-pins.sh`
   renders every combination with an empty env file **and explicitly unsets the variable**, so
   this repository's own audit path cannot pick it up whatever the caller's environment holds.

### With no key it idles — that is the design, not a gap

`restart: unless-stopped`, like the batcher and the poster: the process is meant never to exit,
its state is in the database, and an exit is a crash for which restarting is right. So
`packages/price-feed/src/run.ts` deliberately does **not** exit when the key is missing in loop
mode — it logs one warning at start and one on every tick and does nothing else. A service that
exited 64 there would restart-loop forever, printing the same line, on a stack that quotes
perfectly well from the seeds. `--once` is the mode that reports through its exit code:

| exit | meaning |
|---|---|
| `0` | every asset the cycle asked for was written |
| `2` | the cycle ran and at least one asset did not land |
| `64` | misconfiguration: no key, or a database without the kernel's `000-init.sql` schema |

Failures are **graded**, and that is why `feed.last_error` exists. One bad id inside an
otherwise good response fails only that id. A failed *request* is recorded against every id it
carried — blaming one would be a guess — and the next batch is still made. A `429` stops the
cycle where it stands, keeping what was already written. None of that is an exit code and none
of it is a crash, so `GET /v1/prices` `feed.last_error` is the only place a partial failure is
visible; `./verify.sh`'s `prices` section asserts it is null.

### No port, no volume, and no healthcheck

Nothing is published: the service serves no requests, and its output is rows the kernel already
exposes. Nothing is mounted: its only durable state is `asset_prices` and `price_feed_status` in
the shared `postgres` volume, which is also why `./down.sh -v` needs no change for this profile.

And no healthcheck, deliberately. A loop that sleeps 24 h between cycles has no cheap
in-container liveness signal; the honest question is "did the last cycle succeed", which is a
row in the database served by the *kernel*. A process-liveness probe would report `healthy` for
a feed that had been failing every cycle for a week — and `unhealthy` for a perfectly good one
that simply has no key — so it would be worse than none. `up.sh` asserts the weaker property
that is genuinely readable (the container is running and stays running, restart count
unchanged — `wait_compose_running`), and `./verify.sh`'s `prices` section asserts the real one.

### Why it is its own profile

It needs a third party and an API key, which nothing else here does, and the stack is complete
without it. Upstream keeps it behind a native `profiles: ["prices"]` for the same reason and
does not run it in development at all. `--all` includes it here because in this repository a
profile IS a fragment and `--all` means every fragment — which stays true only because the
key-less case is a working, supported configuration.

## The `shielded-night` profile — the Shielded NIGHT dApp

### What it is

[`effectstream/shielded-night`](https://github.com/effectstream/shielded-night) is a Compact
contract plus a Vite/React page that converts native **unshielded NIGHT** into a
contract-minted **shielded wrapper token, sNight**, and back, 1:1, backed by a pool of NIGHT
the contract locks. It offers two conversion models:

| model | circuits | transactions | wallet approvals |
|---|---|---|---|
| **atomic** | `convertToShielded` / `convertToUnshielded` | one each way | one each way |
| **two-step (credit-bridged)** | `depositUnshielded` → `withdrawShielded`, `depositShielded` → `withdrawUnshielded` | two each way | two each way |

Eleven circuits in total (the nine above plus the sealed metadata readers `name`, `symbol`,
`decimals`, `tokenColor` and `getBalance` — see the profile's verify section, which names all
eleven). The ledger state is a `Map<Bytes<32>, Uint<128>>` of credits keyed by `hash(secret)`
plus the sealed `"Shielded Night"` / `"sNight"` / `6` metadata.

**The sNight colour is derived from the contract address**
(`tokenType(pad(32,"shielded-night:wrapper"), self())`). That is why the deploy is a one-shot
whose address is persisted and never regenerated: a second deploy would not merely change an
address, it would turn every sNight coin already minted into a different, unspendable token.

### The three services

| service | image target | what it does |
|---|---|---|
| `shielded-night-deploy` | `deploy` (bun) | ONE-SHOT. Deploys the contract once per stack with the `genesis-2` wallet and publishes `contract.json` atomically to the `shielded-night-deploy` volume. `restart: "no"`. Finds an existing `contract.json` → JOINs and exits 0 without deploying. |
| `shielded-night` | `web` (nginx) | Serves the built SPA on container `:10900` plus the compiled contract artifacts under `/contract/compiled/shielded-night/`. Its entrypoint waits for `contract.json` and writes `/config.js`. |
| `shielded-night-verify` | `deploy` (bun) | Never started by `up.sh` (`deploy: { replicas: 0 }`). `./verify.sh` invokes it with `docker compose run --rm` for the on-chain-key check and the round trips. |

It depends on `core` and nothing else — `./up.sh --with shielded-night` alone is legal and
complete. There is no kernel dependency, no Celestia, no Postgres.

### The address-injection lane, and why it is the only one

The page's contract address is normally a **build-time** input (`<NETWORK>_ADDRESS`, through
vite's `envPrefix`). This stack deploys its own contract, so the address does not exist when
the image is built. Upstream therefore resolves
`window.SHIELDED_NIGHT.<NETWORK>_ADDRESS ?? import.meta.env.<NETWORK>_ADDRESS`, and
`images/shielded-night/entrypoint-web.sh` writes that global into `/config.js` at container
start, from the address the deploy one-shot published:

```js
// /config.js, written at container start
window.SHIELDED_NIGHT = { UNDEPLOYED_ADDRESS: "0123…" };
```

`index.html` loads it **before** the module bundle (the build rewrites the tag), `nginx.conf`
serves it with `Cache-Control: no-store` and without an SPA fallback, and `./verify.sh` asserts
all three of those properties plus exact equality with the volume's `contract.json`.

**That is the ONLY runtime override this profile has, and it needs no other.** Unlike the
zswap-da SPA, this page never learns an indexer, node or proof-server URL from us: the
connected wallet supplies them through the dApp connector's `getConfiguration()`. So a
non-default port block changes nothing about the page — there is no URL lane to get wrong.

### Why there is no in-page wallet, and what that means for testing

The page enumerates `window.midnight.*` (dApp-connector API 4.x) and **refuses a wallet that
does not implement `getProvingProvider`**. Proving is wallet-owned by design here: the dApp
hands over the contract's ZK key material and the wallet proves inside its own trust boundary,
so the page never names a proof server and cannot leak a private witness to one it chose.

There is consequently **no seed-based in-page wallet** — unlike the zswap-da template — so a
headless browser cannot exercise a swap. The automated proof that the contract works on this
stack is therefore the **Node-side** one: `./verify.sh` runs upstream's own integration
round trips against this stack (`MN_EXTERNAL_STACK=1`) from a container. The browser flow is a
hand test with Lace on the default port block. See `docs/KNOWN-LIMITATIONS.md`.

### The ZK artifact lane

`vite.config.ts` copies the compiled `src/managed/` into
`dist/contract/compiled/shielded-night/`, and midnight-js's `FetchZkConfigProvider` fetches
`keys/<circuit>.prover`, `keys/<circuit>.verifier` and `zkir/<circuit>.bzkir` from there at
proving time. The provider checks only `response.ok`, so `nginx.conf` serves that prefix with
`try_files $uri =404`: a missing artifact must be a 404, never a 200 of the app shell, or the
prover would be handed an HTML document as a proving key. `./verify.sh` fetches all 33 files
and additionally asserts that a circuit name that does not exist answers 404.

### Provenance

The image is built from a pinned full commit of `effectstream/shielded-night`, carries **no
patch of any kind**, and **recompiles the contract in-image with compactc 0.31.1**, failing the
build if the output is not byte-identical to the tree's committed `src/managed/`. That
byte-exactness is the dApp's verifiability claim, and `./verify.sh` closes the loop by
asserting the deployed contract's on-chain verifier keys equal the served ones, 11 of 11. See
`images/shielded-night/PROVENANCE.md` and `config/artifact-decisions.json`.

### sNight on the offer book — the reason this dApp is in an OFFERS stack

Native NIGHT cannot be traded on the offer-files book: the book trades **shielded** tokens and
NIGHT is unshielded. Wrapped, it can be. Two things make that real when the `offerfiles`
profile is also up, and both are additive — neither profile depends on the other:

* **The colour gets a name.** sNight's colour derives from the contract address, so it is
  different on every fresh stack and cannot be written down anywhere. At the end of bring-up
  `up.sh` runs the `shielded-night-token-name` one-shot, which derives it exactly as the page
  does (`rawTokenType(pad(32,"shielded-night:wrapper"), address)`) and registers it with the
  kernel's dev registry (`POST /v1/known-tokens`, symbol `sNight`). Without it the zswap-da SPA
  shows an sNight offer as 64 hex characters. The one-shot is idempotent (the kernel answers
  409 on a re-run) and exits 0 with one line if there is no kernel on the network.
* **`./verify.sh` drives the whole chain.** Its `book` subsection — which runs *if and only if*
  the `offerfiles` profile is up — wraps NIGHT into sNight, posts a real MIP-0005 offer file
  giving that sNight against one of the stack's minted demo colours (through the kernel's own
  `post-maker-offer.ts`, the same code path the repository's `maker-offer` one-shot uses),
  finds it in the book on the sNight colour, has a second wallet balance and settle it, and has
  that wallet convert the sNight it *bought* back into native NIGHT. Exact balances at every
  step. See `docs/OPERATIONS.md` for the knobs and the time budget.

The last step is the one the browser cannot do: the page can only unwrap coins it minted
itself, because it remembers their nonces in `localStorage`. The taker in the chain never
wrapped anything — its sNight arrived inside somebody else's offer file — and the Node-side
driver discovers the coin from the wallet's own synced state.

### sNight is a PRICED asset, and the kernel's sponsorship gate (phase G)

The kernel's `main` (PR #54/#56, which `KERNEL_REF` now pins) prices offers against a
reference-asset table and decides, per offer, whether it is worth paying the Celestia
publishing fee for — the batcher holds the wallet that pays it and is the authoritative gate;
the node's `POST /v1/offers` pre-check is only a mirror of the same rule.

Once `offerfiles` is also up, `shielded-night-token-name` registers sNight not just with a
name but **priced**: `POST /v1/known-tokens` carries `asset_id: "midnight-3"` — the SAME
CoinGecko reference native NIGHT itself is seeded against — and `decimals: 6`, the literal
constant (phase H2, question Q14). Earlier (phase G) this value was read LIVE off NIGHT's own
kernel-pricing row instead of hard-coded, because the kernel's seed was WRONG at the time
(registered NIGHT at 0, off by 10^6 against its real value — 1 NIGHT = 10^6 Stars). Kernel PR
#60 (this project's own upstream fix) corrected the seed, so **6 is now correct by construction
against the fixed seed**, not a guess — and this contract's own on-chain *display* decimals
(`SHIELDED_NIGHT_DECIMALS=6`) happens to share the same value, though it remains a DIFFERENT
convention (the kernel's *pricing-table* decimals is "base units per priced coin"; neither is
read here any more). The one-shot still reads NIGHT's own row live and asserts it equals 6 —
a LOUD failure, naming the `KERNEL_REF` pin, if a kernel re-pin or re-seed ever regresses it —
rather than silently mirroring whatever NIGHT says. One sNight is one wrapped NIGHT, so pricing
it as a second unit of the same asset is not an approximation — it is the actual relationship,
and `GET /v1/quote` for sNight↔NIGHT answers `market_rate: 1` as a result. `./verify.sh`'s
`kernel` section asserts NIGHT's decimals, sNight's decimals, the quote and NIGHT's per-base-
unit price (against its seeded USD coin price / 10^6, as an exact decimal string) when
`shielded-night` is up.

**Defaults, and what stays true because of them:** `BATCHER_SPONSOR_POLICY=warn` and
`BATCHER_SPONSOR_UNPRICED=allow` (upstream's own rollout defaults, kept here). Every sNight
offer this profile's `verify.sh` posts is therefore sponsored regardless of its price — `warn`
logs what `enforce` would have refused instead of refusing it, which is what lets the demo
faucet colours (DEVA/DEVB/DEVU, deliberately left **unpriced** — see `.env.example`'s
`PRICE_FEED_MAP`) keep trading at all: an `enforce` deployment with no reference price for a
token refuses every offer that uses it unless `BATCHER_SPONSOR_UNPRICED=allow` is also set.

**What `BATCHER_SPONSOR_POLICY=enforce` would need, if ever turned on for this stack:** every
tradeable colour would need either a `PRICE_FEED_MAP` entry or a registered `asset_id`, because
an unpriced leg under `enforce` + `BATCHER_SPONSOR_UNPRICED=reject` refuses outright — DEVA and
DEVB have no real-world reference asset, so `enforce` here would need either accepting them as
permanently unpriced-but-allowed (`BATCHER_SPONSOR_UNPRICED=allow` even under `enforce`, the
narrower change), or fabricating a reference price for a token that has none (rejected as worse
than leaving it unpriced — see `.env.example`). This repository does not turn `enforce` on; it
documents the knob and keeps the defaults that make every existing offer keep flowing.

### What else the page offers

Upstream's committed `frontend/.env` carries the live **Preview** and **PreProd** contract
addresses, so the network dropdown shows both alongside *Local (undeployed)*. That is upstream's file,
unmodified — this profile adds a network rather than removing one. Only *Local (undeployed)*
has anything to do with this stack.
