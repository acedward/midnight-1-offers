# Components

> **Scope.** This file documents the source pins that decide which LINE the stack runs, the
> **`solver`** profile's own processes, the **`poster`** profile, the **`prices`** profile, the
> **`shielded-night`** profile and the **`issuer`** profile. The component notes for `core`,
> `offerfiles` and `frontend` are still to be written; `README.md` remains the map of the
> stack.

## Source pins, and the line they put this stack on

Every external identity lives in `config/artifact-decisions.json`; these are the ones that decide
what the stack *means* rather than merely which bytes it runs.

| Pin | Value | Line |
|---|---|---|
| `NODE_IMAGE` | `midnightntwrk/midnight-node` **1.0.1**, index digest `a340cdea456d58d79c0d0e6c8891a3988b472febc228496d33c8448cc1b5b632` | the 1.x chain, **ledger 8.1.0** (1.0.1 bumped it from 8.0.2, so the node now sits on the same 8.1 line as proof-server 8.1.0, the kernel's `@midnight-ntwrk/ledger-v8` 8.1.0 and shielded-night's). Toolkit 1.0.0 and runtime 1.0.0 are unchanged. Re-pinned from 1.0.0 in 00020 PR A — **not breaking**: the `undeployed` genesis bytes `CFG_PRESET=dev` loads are identical in both images, so an existing chain volume keeps working (measured; see `docs/OPERATIONS.md`) |
| `KERNEL_REF` | `a608fa67419c16188e9405417ecdf34f3f7c47a1` — `effectstream/zswap-offerfiles-kernel` `main` | ledger-v8 / 1.x, **the whole-coin line** (kernel #61/#63/#66) plus **#68** (blank-aware price-feed/batcher knobs, the mint's name registration repaired) |
| `FRONTEND_REF` | `58ab921be5513b77937a37be86bf724a41888302` — `effectstream/effectstream` `midnight-1`, subtree `templates/zswap-da` @ `3ca1d56ffc29f03c73cf43432bdfeeaf3ab43c6b` | the same line's UI (effectstream#918) |
| `SHIELDED_NIGHT_REF` | `f7fcefa7921bf2c3f634871f9ad3aa3a32251af0` — `effectstream/shielded-night` `main` | unchanged |
| **`ISSUER_REF`** | `7ecad008b07acb2a491d8291e05455cbd638910f` — `effectstream/mint-test-tokens` `main` | **NEW in 00020 PR B.** The same 1.x line by construction: ledger-v8 8.1.0 (tree-wide `overrides`), compact-runtime 0.16.0, compact-js 2.5.1, midnight-js/testkit 4.1.1, three v1 contracts embedding compactc 0.31.1. It is what replaces the kernel's removed local faucet — see "The `issuer` profile" below |

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

#### `GET /health` IS the solver's container healthcheck (00015)

The `solver` service's compose healthcheck is exactly this route: **200 with `ready: true`, and
nothing else**. What that flag means, read at the pinned kernel rather than inferred — `ready` is
`solverIsReady` in `packages/solver/src/run.ts`, a **one-way latch**:

| it becomes `true` | when all three hold: the book mirror's FIRST sync completed, the kernel's backend projection reported `current`, and the wallet inventory has been read |
| --- | --- |
| it becomes `false` | only in the solver's own `stop()` |

So a healthy `solver` container means **"this solver finished starting up and is still running"**.
Two things it deliberately does **not** mean:

* it says nothing about the **relay socket** — the relay is not part of the latch, and stopping
  the relay leaves the container healthy;
* a backend projection lost *later* does not clear it either (the latch does not re-evaluate).

The end-to-end guarantee — *the relay advertises this solver's ladder* — is asserted directly by
`./verify.sh`'s `solver` section, which is the right place for a claim about three services.

During startup the listener is bound **before** the wallet, so `/health` answers `ready: false`
rather than refusing connections: the container sits in `starting` until the solver is genuinely
up, which is what `start_period: 180s` is for.

**Why it is not the old check.** Until 00015 the healthcheck probed the *relay's* `GET /tokens`
and called the solver unhealthy whenever that list was empty while the kernel book was not. The
solver enters exactly that state by design on every fail-closed empty ladder
(`cache-not-current`), so the check flipped 0/1 about once a minute on an idle stack and 30
consecutive unlucky samples would have marked a correct solver unhealthy. A fail-closed
withdrawal is the solver working.

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

### The four services

| service | image target | what it does |
|---|---|---|
| `shielded-night-deploy` | `deploy` (bun) | ONE-SHOT. Deploys the contract once per stack with the `genesis-2` wallet and publishes `contract.json` atomically to the `shielded-night-deploy` volume. `restart: "no"`. Finds an existing `contract.json` → JOINs and exits 0 without deploying. |
| `shielded-night` | `web` (nginx) | Serves the built SPA on container `:10900` plus the compiled contract artifacts under `/contract/compiled/shielded-night/`. Its entrypoint waits for `contract.json` and writes `/config.js`. |
| `shielded-night-verify` | `deploy` (bun) | Never started by `up.sh` (`deploy: { replicas: 0 }`). `./verify.sh` invokes it with `docker compose run --rm` for the on-chain-key check and the round trips. |
| `shielded-night-token-name` | `deploy` (bun + `psql`) | Never started by `up.sh` implicitly (`deploy: { replicas: 0 }`); `up.sh` runs it explicitly when the `offerfiles` profile is up too. Patches the kernel's seeded `SNIGHT` row with this stack's colour, then registers it — see "sNight on the offer book" above. Exits 0 with one line when there is no kernel on the network. |

It depends on `core` and nothing else — `./up.sh --with shielded-night` alone is legal and
complete. There is no kernel dependency, no Celestia, no Postgres. The one service that DOES
need a kernel and a database, `shielded-night-token-name`, is also the one service compose never
starts on its own: it checks for a kernel first and exits 0 in seconds when there is none, which
is why the profile can carry it without acquiring a dependency. (Its `PG*` variables and the
`postgresql-client` in the `deploy` image exist for the registry patch alone.)

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
  does (`rawTokenType(pad(32,"shielded-night:wrapper"), address)`) and makes the kernel's dev
  registry say so. Without it the zswap-da SPA shows an sNight offer as 64 hex characters. It
  exits 0 with one line if there is no kernel on the network, and it does two things in this
  order:

  1. **patches the kernel's seeded `SNIGHT` row** with this stack's colour — `psql -f
     /usr/local/lib/shielded-night/sql/snight-registry-patch.sql`, the statement the kernel's
     own `000-init.sql` comment prescribes. The kernel seeds that row at the **preview**
     contract's colour, `known_tokens.name` is UNIQUE, and `POST /v1/known-tokens` checks the
     name *before* the colour — so without the UPDATE the real colour could never be registered
     under its own name. It waits for `/v1/health`, then `/v1/health/sync` reporting `ok`, then
     the midnight-node past **block 1**, because the kernel applies that seed while its database
     comes up. `UPDATE 0` on every later run: the statement is idempotent by its own `WHERE`
     clause. (00015; the `deploy` image carries `postgresql-client` for this and nothing else.)
  2. **registers it** (`POST /v1/known-tokens`, symbol `sNight`, `decimals: 6`,
     `asset_id: midnight-3`). On a seeded kernel this answers the **same-colour 409**, which is
     success and is what genuine idempotence looks like here; a 201 happens only on a kernel
     that seeds no `SNIGHT` row.

  Nothing here deletes a registry row. If this stack's colour is already registered under
  *another* name, the one-shot prints the registry and refuses rather than patch through a
  `UNIQUE(token_color)` violation.
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

## The `issuer` profile — this stack issues its own test tokens

### What it is, and why it exists at all

Until 00020 the only token source in this stack was the offer-files kernel's **own faucet
contract**: `offerfiles-deploy` deployed it and minted `DEVA`/`DEVB`/`DEVU`, and the SPA's Faucet
tab minted through it in the browser. Kernel
[#69](https://github.com/effectstream/zswap-offerfiles-kernel/pull/69) **removed that contract.**
On Preview/Preprod/Stagenet tokens now come from the hosted
[`mint-test-tokens`](https://github.com/effectstream/mint-test-tokens) registry, and upstream's own
words are that *a public faucet cannot fund a fresh local chain*. So an `undeployed` stack has to
**issue its own**, and that repository — public, first-party, and already on this stack's exact 1.x
line — supports exactly that (`MN_NETWORK=undeployed`).

The profile deploys the six canonical v1 token contracts **once per chain**, publishes their
registry on a shared volume, serves the static faucet site for humans, teaches the offer-files
kernel the six colours, and exposes one headless command that every other profile's provisioning
calls.

### The six tokens — and why every amount in this stack is now a BASE-UNIT count

| Kernel name | Registry symbol | Privacy | Decimals | Reference asset | 1 whole coin |
|---|---|---|---|---|---|
| `TWBTC` | `twBTC` | shielded | **8** | `bitcoin` | `100000000` |
| `TWETH` | `twETH` | shielded | **18** | `ethereum` | `1000000000000000000` |
| `TWUSDC` | `twUSDC` | shielded | 6 | `usd-coin` | `1000000` |
| `TWUSDM` | `twUSDM` | shielded | 6 | `usdm-2` | `1000000` |
| `UTWUSDC` | `utwUSDC` | **unshielded** | 6 | `usd-coin` | `1000000` |
| `UTWBTC` | `utwBTC` | **unshielded** | 8 | `bitcoin` | `100000000` |

The kernel's name is the registry's symbol upper-cased, and nothing else — that is exactly what
`POST /v1/known-tokens` does to whatever it is sent, so any other transformation would produce a
name that could never match a row the kernel seeds.

**This ends the whole-coin line's "6 decimals everywhere" simplification.** Kernel #63 made every
token 6 decimals and every price per-base-unit; these six are 8, 18 and 6, so an amount is only
unambiguous as a count of BASE UNITS. `issuer-fund` therefore takes base units and refuses
anything that is not plain decimal digits, and the receipt it prints states the decimals beside
the amount.

### Four services and one command

| Service | Target | What it does |
|---|---|---|
| `issuer-deploy` | `runtime` | **ONE-SHOT, MANDATORY.** Funds the dedicated `issuer` wallet with four large NIGHT UTXOs from `genesis-1` under the shared `genesis-lock`, registers that NIGHT for DUST, waits for the DUST to arrive, then runs the pinned repository's **own** v1 deploy: six contracts deployed, each verified on chain, and `metadata.undeployed.json` published atomically onto the `issuer-registry` volume. |
| `faucet` | `faucet` (nginx) | Serves the repository's built static site on container `:10500` (`${FAUCET_HOST_PORT}`) plus that registry and the v1 proving artifacts. **The human lane.** |
| `issuer-registrar` | `runtime` | **NEVER STARTED BY `up.sh` IMPLICITLY** (`deploy: { replicas: 0 }`). Teaches the kernel the six colours: `UPDATE known_tokens … WHERE upper(name) = …` then `POST /v1/known-tokens`, per token. Run when the `offerfiles` profile is up too. |
| `issuer-fund` | `runtime` | **NEVER STARTED AT ALL.** `docker compose run --rm issuer-fund <TOKEN> <base-units> <recipient-seed>` — the headless exact mint. |
| `issuer-registry` | `runtime` | **NEVER STARTED AT ALL.** Validates and dumps the registry. `docker compose run --rm --no-deps issuer-registry`. |

### It depends only on `core`

node, indexer and proof-server — nothing else. `./up.sh --with issuer` alone is legal and
complete: it deploys the six contracts, publishes the registry and serves the faucet. There is no
offerfiles dependency, no kernel, no Celestia, no Postgres, and
`scripts/verify-compose-pins.sh` renders `core issuer` alone to keep that true.

The ONE service that knows the kernel exists therefore cannot say so in compose: compose **rejects**
a `depends_on` — even `required: false` — naming a service no selected fragment defines, which is
precisely the case when `issuer` is up without `offerfiles`. So `issuer-registrar` is
`replicas: 0` and `up.sh` runs it explicitly when `service_present kernel`. That is the same model
`shielded-night-token-name` has used since 00015, for the same reason.

**One difference from the sNight one-shot, and it is deliberate:** a failure of the sNight
registration is a WARNING, because a colour without a friendly name is cosmetic. A failure here is
**FATAL to the bring-up**, because the kernel would be left holding the six canonical NAMES at the
public **Preprod** colours its own seed shipped (kernel #69) — six rows that confidently
misidentify colours which do not exist on this chain, so every quote, price and sponsorship
decision touching a `TW*`/`UTW*` name would be made against the wrong colour. That is worse than
no label at all.

### The wallet, and the genesis-1 mutex

`ISSUER_SEED` is `…0051` in `wallets/wallets.json`, **dedicated** and assigned to nothing else.
The deploy runner holds a wallet facade open through six proving deployments, and `genesis-1` is
already the faucet, the kernel's `MIDNIGHT_WALLET_SEED` and the source every other provisioning
one-shot draws from; two facades on one seed against one Midnight node force each other's
connection down with no error naming the cause. So:

* `images/issuer/m1/provision.ts` exits **78** if it is handed the genesis seed, rather than
  trusting the default;
* `issuer-fund` refuses to mint to the issuer's own seed;
* both hold a `flock` on the `issuer-state` volume, so two issuer containers cannot drive `…0051`
  at once;
* `issuer-deploy` takes the shared **`genesis-lock`** (00011 Q7) for the ~1 minute it spends on
  `genesis-1`, and **releases it before it starts deploying** — the long half of the one-shot does
  not block `solver-provision`, `maker-offer` or `poster-provision`.

**Nothing in mint-test-tokens registers NIGHT for DUST** — it is written for wallets that arrive
already funded — so `m1/provision.ts` does it, with the recipe read out of the published
`@effectstream/midnight-contracts` and re-expressed against the wallet facade this tree already
installs. It is not IMPORTED from that package: that would put a second ledger-v8 wasm instance in
the image's dependency graph, and two instances fail `instanceof` during proving.

### Resume, and what a chain reset does

The deploy runner keeps a private **resume journal** and its private-state stores under
`<repo root>/.local` — the `issuer-state` volume — keyed by
`sha256(registry path + stack identity)`, where stack identity is
`sha256(chain name + runtime version + genesis hash)` read live off the node. A second `./up.sh`
therefore re-verifies each recorded contract on chain and prints `[resume] <symbol> <address>`
instead of deploying. **Measured: 9 seconds for all six, and the registry revision is byte-identical
afterwards.**

`./down.sh -v` wipes the chain and both issuer volumes together, so the ordinary reset leaves
nothing stale. A registry that SURVIVES a chain reset (an operator who wiped only the node volume)
is seen as a different stack identity, marked `stale`, and **refused** with an instruction to
confirm the reset and rerun with `MN_REDEPLOY_STALE=1`. The entrypoint does not set that by
default — posting stale ids to the kernel is the failure this profile exists to prevent, and
"discard six contracts' worth of identity" is an operator's decision, not a bring-up's. Pass
`ISSUER_REDEPLOY_STALE=1` when you have made it.

### The browser lane is a HAND TEST, on purpose

The faucet site mints through a connected dApp-connector 4.x wallet (Lace) and **the wallet does
the proving**, so there is no headless path through the site at all. That is why `issuer-fund`
exists, why every automated gate uses it, and why the browser flow is the owner's hand test
(`docs/OPERATIONS.md`).

### Provenance

`images/issuer/PROVENANCE.md` carries the whole story. The three things worth knowing here:

1. **The image keeps its `.git`, detached at the pin.** The deploy runner runs `git rev-parse HEAD`,
   `git diff` and `git ls-files --others` over `contracts/v1` before it will submit anything, and
   records the resolved commit in every registry record as `artifact.sourceRevision`. An image
   without the repository cannot issue a token — and the registry this stack publishes therefore
   names the exact source revision its verifier keys came from.
2. **All three v1 contracts are recompiled in-image** with compactc 0.31.1 and must reproduce the
   committed `contracts/v1/managed/` **byte for byte** (measured: 5 + 5 + 9 circuits, zero
   differences). Unlike `images/shielded-night`, the fresh bytes are NOT copied forward — the
   runner requires the working tree to equal the pinned commit, so the committed bytes are the ones
   that ship and the equality is proven instead.
3. **`images/issuer/nginx.conf` transcribes upstream's `frontend/public/_headers`**, and that file
   is pinned by SHA-256 in the Dockerfile — so a re-pin that changes the header policy fails the
   BUILD and names the config, instead of leaving nginx describing a policy upstream no longer has.

## Appendix — the profile descriptions that used to sit in the README's profiles table

Moved here on 2026-09-07 when the README table became a per-profile service/endpoint table
plus a generated pin table. **The refs quoted below are as of that date and are NOT
maintained** — the live pins are the README's generated table and
`config/artifact-decisions.json`. The prose is kept because it says what each profile is for.

| Profile | Fragment | What it runs |
|---|---|---|
| `core` | `compose/core.yml` | midnight-node 1.0.1, indexer-standalone 4.3.3, proof-server 8.1.0 (+ its proof-data pre-warm), PostgreSQL with `pg_ivm`. **Unconditional** — every `up.sh` includes it. |
| `offerfiles` | `compose/offerfiles.yml` | Celestia DA devnet, the offer-files contract deploy one-shot, the kernel API (`:9999`) and the batcher (`:3334`), built from `effectstream/zswap-offerfiles-kernel` **main** — which includes the COW-solver line, seeded reference asset prices (`GET /v1/prices`), the batcher's sponsorship gate (`BATCHER_SPONSOR_POLICY=warn` / `BATCHER_SPONSOR_UNPRICED=allow` by default) and, since `c293ebd`, **the whole-coin line**: every registered token is at 6 decimals, one faucet press mints 1 000 whole coins (`1000000000` base units), and prices are served PER BASE UNIT (`WBTC` = `0.077387`). Since `a608fa6` (kernel #68) the upstream mint also registers its own `TESTTOKEN*` names — it cannot reach a kernel from this stack's deploy one-shot, and `offerfiles-token-names` now fails loudly rather than accept a foreign name for one of our colours. **Re-pinning past a stack that already ran a `KERNEL_REF` OLDER THAN `c293ebd` is BREAKING for its Postgres volume — see `docs/OPERATIONS.md`, `./down.sh -v` is the upgrade path; the `c293ebd` → `a608fa6` step is not.** |
| `frontend` | `compose/frontend.yml` | the `zswap-da` SPA (`:10600`), built from the frozen `effectstream/effectstream` template — v8-native at that ref, so **no** ledger patch. Includes the reference-rate / sponsorship-threshold UI (effectstream#916) and, since `58ab921`, **whole-coin amounts** (effectstream#918): the page reads each token's `decimals` off the registry, so the faucet says `1,000` and a take moves the balance by exactly the coins shown. |
| `shielded-night` | `compose/shielded-night.yml` | the **Shielded NIGHT** dApp (`:10900`): a deploy one-shot that mints the NIGHT ⇄ sNight wrapper contract **once per stack**, and an nginx page that learns that address at container start. Built from `effectstream/shielded-night` at a pinned commit, with the contract **recompiled in-image** (compactc 0.31.1) and required to reproduce the committed artifacts byte-for-byte. **Depends only on `core`.** With `offerfiles` also up it names the sNight colour in the kernel's token registry **and prices it** (`asset_id: midnight-3`, the same reference NIGHT itself uses — `GET /v1/quote` sNight↔NIGHT answers `market_rate: 1`), and `./verify.sh` drives the whole chain — NIGHT → sNight → an offer file on the book → taken → back to NIGHT. |
| `solver` | `compose/solver.yml` | the Midnight Intents relay (`:13000` HTTP, `:19001` solver WS), the COW solver in execution mode with its read-only **status listener** (`:9100`, bearer-gated, network-internal by design), the **solver monitor** (`:10800` — the six-stage health strip, the published ladder and the book, read-only), the provisioning one-shots, and the intents browser UI (`:10700`). The solver **is the kernel commit**: `images/cow-solver` is the kernel image plus entrypoints, with no second source pin and no `.solver-commit` — see `docs/COMPONENTS.md`. |
| `poster` | `compose/poster.yml` | the **offer poster** (`:19977` — read-only `/health`, `/metrics`, `/journal`) and the one-shot that funds its DEDICATED wallet with NIGHT from genesis. Every 60 s it either re-offers a coin that came back or mints one whole WBTC coin from the faucet circuit — paying the fee from its own DUST — and posts **one** ZSwap offer whose only input is that exact coin, sized from `GET /v1/quote` so the batcher sponsors it. Each offer spends its coin **whole**: no change output, so every offer is a complete, independently takeable swap. **Opt-in**, and included by `--all`; it needs `offerfiles` and needs neither the relay nor the solver. `./verify.sh` asserts the exact-coin guarantee from outside (`computed.inputNullifiers` == the journal coin's nullifier) and settles one of its offers with a second wallet. |
| `issuer` | `compose/issuer.yml` | **THIS STACK'S OWN TOKEN ISSUER** and the faucet site for it (`:10500`) — what replaces the local faucet contract kernel #69 removed. `issuer-deploy` deploys the six `mint-test-tokens` v1 token contracts once per chain (`TWBTC` 8 dec, `TWETH` 18, `TWUSDC` 6, `TWUSDM` 6, `UTWUSDC` 6 unshielded, `UTWBTC` 8 unshielded), publishes `metadata.undeployed.json` on the `issuer-registry` volume, and the `faucet` container serves the repository's own static site at `/?network=undeployed` for a Lace-driven mint. **Depends only on `core`.** With `offerfiles` also up, `issuer-registrar` teaches the kernel all six colours with their real decimals (`UPDATE` by name, then `POST /v1/known-tokens`). Automation never uses the browser: `docker compose run --rm issuer-fund <TOKEN> <base-units> <recipient-seed>` mints an exact amount headlessly and reads the recipient's balance back. **Opt-in**, and included by `--all`. |
| `prices` | `compose/prices.yml` | the **price feed** — one process, no port and no volume, on the kernel image. Every `PRICE_FEED_INTERVAL_MS` (24 h) it asks CoinGecko `simple/price` for the five seeded assets (`bitcoin`, `ethereum`, `usd-coin`, `midnight-3`, `usdm-2`) in **one batched request** and upserts `asset_prices`, so `GET /v1/prices`, `GET /v1/quote`'s `market_rate` and the batcher's sponsorship gate move from the schema's 2026-09-02 seeds (`source: seed`) to live prices (`source: feed`). `COINGECKO_API_KEY` in `.env` is the **only secret in this stack**: sent as the `x-cg-demo-api-key` header, never as a query parameter, never printed (the service logs `key=present`), never given a compose default. **Opt-in**, and included by `--all`; it needs `offerfiles` (the image, and the kernel's schema). **With no key it comes up and idles with a warning rather than crash-looping** — the seeded prices already quote real ratios — and `./verify.sh` reports its section **SKIPPED**, never passed. Take a refresh now with `docker compose run --rm --no-deps price-feed --once`. |
