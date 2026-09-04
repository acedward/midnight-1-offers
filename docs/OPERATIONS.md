# Operations

> **Scope.** This file documents the **`solver`** profile's monitor and status listener, the
> **`shielded-night`** profile, and the `offerfiles`-profile notes that each kernel re-pin makes
> unavoidable for anyone running an existing stack forward. The rest of the `offerfiles`
> profile's operating notes are still to be written.

## Re-pin to kernel `main` @ `c293ebd` (00011 PR A) — **BREAKING for an EXISTING stack**

This is the newest re-pin and the one to read first.

`KERNEL_REF` is now `c293ebd57937c0065663b08b2c244438be8989a5` and `FRONTEND_REF` is
`58ab921be5513b77937a37be86bf724a41888302`. **They move together**, because the change is one
change split across two repositories.

### What moved

| Upstream | What it brings |
|---|---|
| kernel [#61](https://github.com/effectstream/zswap-offerfiles-kernel/pull/61) | sNight is SEEDED as a default known token — at the **preview** contract's colour. See the caveat below. |
| kernel [#63](https://github.com/effectstream/zswap-offerfiles-kernel/pull/63) | **The whole-coin line.** `known_tokens.decimals` DEFAULTS to **6** instead of 0; the seeded NIGHT/SNIGHT/USDC/USDM rows are all 6; every faucet mints **whole coins** scaled by 10^6. One faucet press is 1 000 coins = `1000000000` base units. Prices are served PER BASE UNIT, so `WBTC` reads `0.077387` (= 77387/10^6) and `WETH` `0.00239328` (= 2393.28/10^6). |
| kernel [#66](https://github.com/effectstream/zswap-offerfiles-kernel/pull/66) | the offer-poster's give-size range. Nothing in this repository runs the poster yet. |
| effectstream [#918](https://github.com/effectstream/effectstream/pull/918) | the **UI half** of #63: the SPA reads each token's `decimals` off `GET /v1/known-tokens`, scales every amount it displays and submits by `10^decimals`, sends an explicit `decimals` when registering a minted colour, and mints **1 000 whole coins**. |

(kernel #62 put ledger-v9 on `main` by mistake and #64 reverted it — net zero. #65 re-opens it
and is still OPEN; this repository stays on the v8 line and both images assert it at build.)

### Why it is BREAKING, and what breaks

`packages/database/migrations/000-init.sql` is **one file, applied fresh, exactly once**, against
an empty database. There is no migration runner and nothing here adds one. So a `postgres` volume
created under an older `KERNEL_REF`:

* keeps `known_tokens.decimals DEFAULT 0` forever — every colour registered afterwards without an
  explicit `decimals` lands at **0**, and prices for it are wrong by a factor of 10^6;
* keeps the old seed rows, and never gains the new ones.

Unlike the phase-G re-pin, **nothing fails loudly on its own**: the schema SHAPE did not change,
so the kernel starts, the healthcheck goes green, and the stack merely lies about every price.

`./verify.sh`'s `kernel` section is what catches it. Its `token decimals` block sweeps every row
of `GET /v1/known-tokens` and fails naming the offenders; a row at `0` is reported as
**STALE POSTGRES VOLUME** with this command as the fix:

```sh
./down.sh -v          # wipes the chain, Celestia and the DB schema together
./up.sh --all         # fresh contracts, fresh schema, fresh seed rows
```

On a devnet — which is all this repository ever runs — that is the correct and only upgrade path:
the book, the Celestia history and the deployed contracts are projections of the chain `down.sh
-v` already wipes, so wiping the schema alongside them loses nothing.

### The sNight seed caveat (kernel #61) — handled, but know it is there

`000-init.sql` now seeds a `SNIGHT` row at the colour derived from the **preview** shielded-night
contract (`793c29c9…`). That colour cannot exist on an `undeployed` devnet: this stack deploys its
own wrapper contract and derives a different colour every time. Because `known_tokens.name` is
UNIQUE and `POST /v1/known-tokens` upper-cases the name (and checks the name **before** the
colour), the seeded row would otherwise hold the name `SNIGHT` against a phantom colour and leave
this stack's real sNight unnamed — silently, because every registration path treats a 409 as
"already registered".

`up.sh` handles it: `shielded-night-token-name` now reads the registry back on a 409 and exits
**75** when the name is held by a *different* colour; `up.sh` answers that by running

```sql
DELETE FROM known_tokens WHERE upper(name) = 'SNIGHT';
```

against the stack's own Postgres — exactly the hand patch upstream's own comment beside that seed
prescribes — and re-running the one-shot once. Nothing is silent about it: both steps log.

### What `verify.sh` now measures on this line

* every row of `GET /v1/known-tokens` at exactly **6** decimals (and the stale-volume detector);
* the faucet **allotment**, read out of the running kernel image's own pinned tree: 1 000 whole
  coins = `1000000000` base units at 6 decimals;
* the two priced faucet presets registered at 6 decimals and priced per base unit as exact
  decimal strings — `WBTC` `0.077387`, `WETH` `0.00239328`;
* NIGHT still at 6 decimals with its per-base-unit price equal to its coin price / 10^6.

### The browser half — two thirds MEASURED, one third an owner hand test

Automated gates cannot press the SPA's faucet button, so this is recorded here. Open
`http://127.0.0.1:${FRONTEND_HOST_PORT:-10600}` and connect the in-page **JS Wallet** (the
`Connect wallet` dialog's third entry — it runs entirely in the browser and needs no extension;
Lace needs the default port block, see `docs/KNOWN-LIMITATIONS.md`, the JS wallet does not).

| # | What the browser must show | Status |
|---|---|---|
| 1 | the faucet reads **`1,000` coins** (not `1,000 units`, not `1,000,000,000`) | **MEASURED 2026-09-03** on the 00011 PR A gate — the Faucet screen reads `1,000 coins` |
| 2 | after minting, the wallet balance reads **`1,000`** of that token | **MEASURED 2026-09-03** — `Minted 1,000 WBTC`, colour `480b6163c0db…a9a2fb26`, and the wallet menu's shielded balance reads `WBTC 480b61…fb26  1,000`. That colour is exactly the one `verify-kernel.sh`'s faucet section derives and registers, so the SPA faucet and the headless probe land on the same colour by construction |
| 3 | creating and taking an offer moves the balance by **exactly the coin amount displayed** — the 00005 P3 `1000 → 999` measurement, re-done at 6 decimals | **OWNER HAND TEST** — it needs a second wallet to take the offer, so it is not something a single automated session can close. `./verify.sh`'s shielded-night `book` section proves the equivalent property on chain, with exact balances, for the sNight pair |

## Upgrading past the kernel re-pin to `main` (phase G) — BREAKING for an EXISTING stack

`KERNEL_REF` now pins `zswap-offerfiles-kernel` `main`, which carries kernel PR #54's seeded
reference-price tables (`asset_prices`, `price_feed_status`, two new `known_tokens` columns).
The kernel's schema is **one file, applied fresh** (`packages/database/migrations/000-init.sql`,
no `IF NOT EXISTS` anywhere) — there is no migration runner and nothing here adds one. An
**existing** stack's shared `postgres` volume still holds the OLD shape and the kernel will
fail loudly against it rather than silently degrade.

**The fix is `./down.sh -v`.** On a devnet — which is what this repository ever runs — that is
the correct and only upgrade path: the offer book, the Celestia history and the deployed
contracts are all projections of the same chain that command already wipes, so wiping the
Postgres schema alongside them loses nothing an operator was relying on. There is no
in-place-upgrade lane, and none is planned — a fresh chain always gets a fresh schema together.

```sh
./down.sh -v                                        # wipes the chain, Celestia, and the DB schema together
./up.sh --with offerfiles --with shielded-night      # fresh contracts, fresh schema, re-run the token-name one-shot
```

If you skip this and bring an old volume forward, `kernel`'s healthcheck fails and its logs
name the missing table/column rather than starting degraded.

The batcher's new **sponsorship gate** (`BATCHER_SPONSOR_POLICY=warn`,
`BATCHER_SPONSOR_UNPRICED=allow` by default) and the standalone price-feed refresh service
(**not run** by this repository — the seeded reference prices are enough offline) are covered
in `docs/COMPONENTS.md`'s "sNight is a PRICED asset" section.

## Re-pin to kernel PR #60 (phase H2) — a SILENT breaking change for an EXISTING stack

`KERNEL_REF` moved again, to `main` after kernel PR #60 (project 00007's own upstream fix,
question Q14): the seeded `known_tokens` row for NIGHT (and the USDC placeholder) changes its
`decimals` value from `0` to `6`. Unlike the phase-G re-pin above, this is **not** a schema
SHAPE change — no table or column is added — so an existing stack's `postgres` volume does
**not** fail loudly. It keeps running, healthcheck green, with the OLD row (`decimals: 0`)
untouched, because the seed file only runs on a fresh (empty) volume. The symptom is silent and
numeric, not an error: `GET /v1/prices` for NIGHT still answers `decimals: 0`, and a freshly
registered sNight would be priced 10^6 off from a genuinely 1:1 relationship — exactly the bug
kernel PR #60 fixed, reappearing on any stack that re-pins `KERNEL_REF` without also wiping its
volume.

**The fix is the same as above: `./down.sh -v`.** There is no in-place row-update lane in this
repository (an operator with direct DB access on a live, non-devnet deployment can instead run
the one-line `UPDATE known_tokens SET decimals = 6 WHERE name IN ('NIGHT', 'USDC');` that kernel
PR #60's own body documents — not applicable here, since this profile only ever runs a
disposable devnet).

## The solver monitor, and reading the solver's status listener (00011 PR B)

```sh
./up.sh --with offerfiles --with solver
open http://127.0.0.1:${SOLVER_FRONTEND_HOST_PORT:-10800}     # the monitor
```

`up.sh` prints the URL as **`solver monitor`** when the stack is up. The page is read-only, has
no authentication of its own, and binds `BIND_ADDR` (127.0.0.1) like everything else here.

**Open it when the solver is misbehaving, not only when it is fine.** It depends on the kernel
alone, so it renders the book, the kernel's sync state and the token registry even with the
solver stopped — and says `SOLVER UNREACHABLE` with the time it was last seen instead of going
blank. The six-stage health strip (kernel sync → book cache → inventory → journal & DUST →
relay socket → published ladder) is designed to answer *which* stage is red, and an empty ladder
is labelled with the solver's own reason (`cache-not-current` = the fail-closed withdrawal;
`withdrawn` = a deliberate one) rather than as "no liquidity".

### Reading the status listener by hand

The listener is on `:9100` **inside the compose network only** — it is not published, because
`/status/*` serves the solver's entire internal state and the monitor is its intended reader:

```sh
# the open liveness route: no bearer, nothing internal in the body
docker compose … exec solver bun -e \
  'const r = await fetch("http://127.0.0.1:9100/health"); console.log(await r.text());'

# the full snapshot: bearer required, read from the container's own environment
docker compose … exec solver bun -e 'const r = await fetch(
  "http://127.0.0.1:9100/status/snapshot",
  { headers: { authorization: "Bearer " + process.env.SOLVER_STATUS_AUTH_TOKEN } });
  console.log(await r.text());'
```

To publish it for a debugging session, uncomment the `ports:` block in `compose/solver.yml`
(`SOLVER_STATUS_HOST_PORT`, default `19100`) — and never with a non-loopback `BIND_ADDR`: the
bearer would then be the only thing between the solver's whole internal state and the network.
`scripts/pick-ports.sh` deliberately emits no port for it.

### Knobs

| variable | default | what it does |
|---|---|---|
| `SOLVER_FRONTEND_HOST_PORT` | `10800` | published port for the monitor (`BASE+11` from `pick-ports.sh`) |
| `SOLVER_STATUS_AUTH_TOKEN` | a committed devnet value, 49 chars | the ONE bearer both sides read. **≥ 32 characters, enforced at startup**: with the status port set, a missing or short value is one of the problems `start.solver.ts` lists before it binds. `pick-ports.sh` emits a random 64-hex one |
| `SOLVER_FRONTEND_POLL_MS` | blank → `4000` | kernel/relay poll interval (250–300 000). The solver half prefers SSE and polls only while the stream is down |
| `SOLVER_FRONTEND_HISTORY_LIMIT` | blank → `500` | transitions kept in memory (1–5000); never persisted |
| `SOLVER_MONITOR_BUDGET_S` | `180` | `verify.sh`: how long the monitor may take to report a relay-connected solver with a non-empty ladder |
| `SOLVER_LADDER_BUDGET_S` | `300` | `verify.sh`: how long the relay may take to advertise both colours after a re-seed |
| `SOLVER_VERIFY_RESEED` | `true` | `verify.sh`: re-seed the book when no live maker offer is left. `false` makes an empty book a FAILURE instead — never a skip |
| `MAKER_OFFER_RESEED` | `false` | the `maker-offer` one-shot: post another offer even though the marker exists. `verify.sh` sets it; an operator restart still JOINs |

**`SOLVER_REPO` / `SOLVER_REF` are retired.** The solver is the kernel commit; set either and
`scripts/lib/common.sh` warns that it is ignored. Move `KERNEL_REF` instead.

### Why `./verify.sh` sometimes posts an offer

The seeded maker offer is not permanent, and neither reason is a defect:

* **expiry** — on this chain an offer lives `min(ROOT_WINDOW_SECONDS, OFFER_TTL_SECONDS)` = **1
  hour**, whatever `MAKER_OFFER_TTL_MINUTES` asks for, because a shielded input can only be
  proved against a Merkle root still inside the chain's window. A long `./up.sh --all` plus a
  full `./verify.sh` can exceed that by itself;
* **consumption** — the kernel archives an offer the moment **any** on-chain transaction spends
  its input nullifier. A settled take does that, and so does an unrelated transfer from the
  maker's own wallet whose coin selection happens to pick the coin the offer reserved. That is
  what the `shielded-night` book chain's taker funding does on an `--all` run: it moves the
  maker's give colour out of the maker's own genesis wallet.

Before 00011 the `solver` section answered an empty book with a WARN and skipped its ladder and
exact-quote assertions — its strongest ones — while still exiting 0. It now reports the offer's
actual terminal status (by hash, from the one-shot's marker), re-seeds through
`maker-offer` with `MAKER_OFFER_RESEED=true`, and fails if that does not restore a ladder inside
`SOLVER_LADDER_BUDGET_S`.

## The offer poster (00011 PR C)

```sh
./up.sh --with offerfiles --with poster       # or --all
./verify.sh --poster                          # assert it is WORKING, not merely alive
```

Two services come up: `poster-provision` (a one-shot that sends the poster's dedicated wallet
four large NIGHT UTXOs from genesis and exits) and `offer-poster` (the loop). The poster
registers that NIGHT for DUST itself, joins the offer-files contract, registers its two token
names so both legs quote at a real price, and then posts one offer a minute.

**The first offer takes minutes, not seconds.** Wallet sync, DUST registration, the bounded
dust wait, the contract join and ~30 s of proving all happen before anything reaches the book —
which is why the container healthcheck has a 15-minute `start_period` and why
`POSTER_VERIFY_BUDGET_S` defaults to 420.

### Reading it

Everything the poster exposes is read-only and needs no bearer (`${POSTER_HEALTH_HOST_PORT}`,
loopback):

| route | what it answers |
|---|---|
| `GET /health` | `{state, ready, ticks, mints, reoffers, lastTickAt, lastOfferId, lastError, dustBalance, liveOffers, freeCoins, p95TickMs, journal}` |
| `GET /metrics` | the same counters in Prometheus text format, plus tick p50/p95 and the overrun count |
| `GET /journal` | the journal as JSON — every coin, its nullifier, and every offer built from it |

```sh
curl -s http://127.0.0.1:19977/health
curl -s http://127.0.0.1:19977/journal      # .coins is keyed by coin nonce
docker compose logs -f offer-poster
```

**`degraded` is a 200 BY DESIGN, and so is `starting`.** A 503 arrives only after
`HEALTH_STALE_TICKS` consecutive FAILED ticks. A poster waiting for NIGHT is not a poster a
restart would fix, so it says `degraded: insufficient_dust` and keeps servicing re-offers
(which cost no dust) rather than dying. That is exactly why a green healthcheck is not evidence
the poster is working, and why `./verify.sh`'s poster section waits for `mints >= 2` and
`liveOffers >= 2` instead of trusting it.

### Checking the exact-coin guarantee by hand

Every offer spends exactly one coin, whole. Compare the two sides:

```sh
# what the poster believes it did
curl -s http://127.0.0.1:19977/journal | grep -o '"nullifier":"[0-9a-f]*"' | tail -1

# what the kernel says the offer actually spends (offerId = the journal's own offerId)
curl -s http://127.0.0.1:9999/v1/offers/<offerId> | grep -o '"inputNullifiers":\[[^]]*\]'
```

One entry, and equal. `./verify.sh --poster` does this automatically.

### A dry run

`DRY_RUN=true` does the whole of startup — build the wallet, sync, register NIGHT for dust,
join the contract, derive both colours offline, register the token names, load the journal,
read one quote — then prints a JSON report and exits 0. It never mints and never posts. Run it
as a ONE-OFF, because the service restarts unless stopped:

```sh
docker compose run --rm -e DRY_RUN=true offer-poster
```

### Knobs

Every `OFFER_POSTER_*` variable in `.env.example` is a passthrough with upstream's own name and
upstream's own blank-means-code-default rule; the entrypoint UNSETS the blank ones so
`docker compose exec offer-poster env` shows what the process actually used. The ones worth
knowing:

| knob | default | effect |
|---|---|---|
| `OFFER_POSTER_GIVE_TOKEN` / `_WANT_TOKEN` | `WBTC` / `WETH` | the pair. The GIVE leg must be a faucet preset **NAME** — the poster mints it and the faucet derives the colour from the name. The WANT leg may be a name or a 64-hex colour, and must be SHIELDED. |
| `OFFER_POSTER_GIVE_AMOUNT` | `1000000` | base units per minted coin — one whole coin at 6 decimals |
| `OFFER_POSTER_GIVE_MIN` / `_GIVE_MAX` | unset | a RANGE in whole COINS instead of the fixed amount, drawn LOG-uniformly per fresh mint so the book carries a spread. **Both ends or neither**, and mutually exclusive with `GIVE_AMOUNT` — blank that line first, or the poster exits 78 naming both. `OFFER_POSTER_SIZE_SEED` makes the sequence reproducible. |
| `OFFER_POSTER_INTERVAL_MS` | `60000` | one tick a minute. An overrunning tick does not queue; the overrun is counted. |
| `OFFER_POSTER_TTL_MINUTES` | `60` | the WALLET's local deadline for an unconfirmed recipe — **not** how long a posted offer stays takeable. A live offer expires on the kernel's clock: `min(ROOT_WINDOW_SECONDS, OFFER_TTL_SECONDS)`, 1 h here, which no client can shorten. |
| `POSTER_PROVISION_ENABLED` | `true` | set false to bring the profile up without funding from genesis (an operator who funds out of band) |
| `POSTER_VERIFY_BUDGET_S` | `420` | how long `./verify.sh` waits for two mints and two live offers |
| `POSTER_VERIFY_SKIP_TAKE` | `false` | skip verify's real settlement of one poster offer (it costs two provings) |

### The genesis-1 facade mutex

`poster-provision` drives the genesis wallet, and so do `solver-provision` and `maker-offer` in
the `solver` profile. Two wallet facades on one seed against one Midnight node force each
other's connection down, and the two fragments cannot `depends_on` each other (compose will not
render a dependency on a service that is not in the merged set, and `--with poster` alone is
supported). So all three take a `flock` on `/srv/genesis-lock/lock`, on a named volume both
fragments declare. If one of them hangs, the others say so:

```
[poster-provision] waiting for the genesis-1 facade lock (/srv/genesis-lock/lock, up to 1800s)
```

`GENESIS_LOCK_TIMEOUT_S` bounds the wait; exhausting it is a failure that names the three
services to check.

### One poster per stack

The service must never be scaled past one replica, for the same reason its seed is dedicated.
Two posters on one seed would fight over the same coins and force each other's connection down.

## Bringing the `shielded-night` profile up

```sh
./up.sh --with shielded-night          # core + the dApp; nothing else is needed
```

`up.sh` blocks until the profile is genuinely usable, not merely started: the deploy one-shot
must exit 0, the web container must pass its healthcheck (`/`, `/config.js` **and** one
verifier key as non-empty bytes), and the published contract address must really be readable
on the volume. The summary line names it:

```
    Shielded NIGHT    http://127.0.0.1:10900   contract 80b89b9a…
```

On a shared machine, use a generated port block instead of the defaults:

```sh
./scripts/pick-ports.sh > .env.test
ENV_FILE=.env.test ./up.sh --with shielded-night
ENV_FILE=.env.test ./verify.sh --shielded-night
ENV_FILE=.env.test ./down.sh -v
```

`SHIELDED_NIGHT_HOST_PORT` is `BASE+10` in a generated block and `10900` by default.

## Redeploy semantics — read this before wondering why the address did not change

**The contract is deployed exactly once per stack.** The presence of `contract.json` on the
`shielded-night-deploy` volume IS the "already deployed" flag: a one-shot that finds one JOINs
that deployment and exits 0 without deploying. Three consecutive `./up.sh` runs and a
`--force-recreate` of the one-shot all yield the same address.

That is deliberate, and it protects more than an address. **The sNight token colour is derived
from the contract address**, so a silent redeploy would turn every sNight coin already minted
into a different token that nothing can spend — with no error anywhere, just a balance that
reads zero.

To force a new contract you must drop the volume:

```sh
./down.sh -v                            # wipes the chain AND this volume — a new chain gets a new contract
```

`./down.sh` without `-v` keeps the chain and the contract, so the next `./up.sh` resumes both.

**After a redeploy the web container must be restarted.** It reads the volume once, at start,
and writes `/config.js` from what it finds. A `./down.sh -v && ./up.sh --with shielded-night`
cycle recreates everything and is therefore fine. If you drop only that volume by hand, follow
it with:

```sh
docker compose … restart shielded-night     # or simply: ./up.sh --with shielded-night
```

`./verify.sh` catches this case for you: it compares `/config.js` byte-for-byte against the
volume's `contract.json` and fails if they have drifted apart.

## Verifying

```sh
./verify.sh                       # runs the shielded-night section if the profile is up
./verify.sh --shielded-night      # …and FAILS if it is not up
./verify.sh --no-shielded-night   # skip it
```

The section asserts, in order: the page serves HTML; `/config.js` is 200, carries **exactly**
the deployed address and is loaded before the module bundle; all 11 circuits' prover, verifier
and bzkir artifacts answer with non-empty bytes while a non-existent circuit answers 404; the
deployed contract's on-chain verifier keys are byte-identical to the served ones (upstream's
own `verify-deployment.ts`, run inside the compose network); and a funded driver wallet
completes both NIGHT ⇄ sNight round trips — atomic and two-step — with exact balance
assertions.

The last two run in a container from the same image the contract was deployed from:

```sh
docker compose … run --rm shielded-night-verify keys
docker compose … run --rm shielded-night-verify roundtrip
```

That service is never started by `up.sh` (it declares zero replicas), so those two commands are
the only way it runs.

**Budget several minutes for the round trips.** Each deploys its own contract instance and
performs real proofs; upstream's own timeout for each test is ten minutes.

## Knobs

| variable | default | what it does |
|---|---|---|
| `SHIELDED_NIGHT_HOST_PORT` | `10900` | published port for the page (`BASE+10` from `pick-ports.sh`) |
| `SHIELDED_NIGHT_REF` | the pinned commit | full 40-hex commit of `effectstream/shielded-night`; anything else fails the build |
| `SHIELDED_NIGHT_REPO` | the public repo URL | source of that commit |
| `SHIELDED_NIGHT_IMAGE` / `SHIELDED_NIGHT_DEPLOY_IMAGE` | `midnight-1-offers/shielded-night{,-deploy}:local` | one build context, two runtime targets, two tags |
| `SHIELDED_NIGHT_WALLET_SEED` | `genesis-2` | the deployer. **The genesis-1 seed is refused outright** (see `docs/WALLETS.md`) |
| `SHIELDED_NIGHT_DRIVER_SEED` | `genesis-2` (`0x…0002`) | the verify round trip's wallet, and the sNight maker in the book chain. Same seed as the deployer on purpose — that one-shot has exited by then (Q6 → D) |
| `SHIELDED_NIGHT_NAME` / `_SYMBOL` / `_DECIMALS` | `Shielded Night` / `sNight` / `6` | sealed into the contract at deploy; they cannot be changed afterwards |
| `SHIELDED_NIGHT_LOCK` | `false` | see below |
| `SHIELDED_NIGHT_WAIT_TIMEOUT` | `600` | how long the web container waits for `contract.json` before failing |
| `SNIGHT_BOOK_AMOUNT` | `1000000` | book chain: how much NIGHT is wrapped, and the size of the sNight leg of the offer. The taker receives it as ONE coin worth exactly this, which is what lets the unwrap step burn it whole |
| `SNIGHT_BOOK_WANT_AMOUNT` | `750000` | book chain: how much of the demo colour the offer asks for |
| `SNIGHT_BOOK_WANT_KEY` | `shieldedA` | book chain: which minted colour to ask for — `shieldedA` is DEVA, `shieldedB` is DEVB |
| `SNIGHT_BOOK_TAKER_SEED` | `e2e-taker` (`0x…0032`) | book chain: the wallet that takes the offer. Empty at genesis; the chain funds it |
| `SNIGHT_BOOK_FUNDER_SEED` | `genesis-1` | book chain: funds the taker. It is the faucet **and** the wallet the demo colours were minted to, so it is the only wallet that can hand the taker the token the offer demands |
| `SHIELDED_NIGHT_SKIP_BOOK` | unset (`0`) | `1`/`true` skips the WHOLE book-chain subsection (below) — not the round trips above it, which always run. For a gate on a time budget that still wants `offerfiles`+`shielded-night` wired together (compose renders, the cross-profile one-shot fires, the sNight pricing and quote are still checked from `verify-kernel.sh`) without paying the book chain's own ~12–20 min of proving |

## The book chain (`./verify.sh`, `book` subsection)

It runs **only** when the `offerfiles` profile is up; otherwise the section prints a SKIP and
the rest of the shielded-night assertions still run. `SHIELDED_NIGHT_SKIP_BOOK=1` skips it
unconditionally even when `offerfiles` IS up (see the Knobs table) — for a gate that wants
everything ELSE this subsection depends on (the cross-profile registration, the sNight pricing)
without its own ~12–20 min of proving. Bring both up with:

```sh
./up.sh --with offerfiles --with shielded-night
./verify.sh --shielded-night
```

Five steps, all in containers built from this stack's own images (no host `bun`, no host
`node`): wrap → post a real MIP-0005 offer file → find it in the book on the sNight colour →
take and settle it from a second wallet → unwrap what that wallet bought.

**Budget 12–20 minutes for it on a cold stack**, on top of the round trips. Seven real proofs
happen in it: the wrap, the offer, three funding transactions for the taker (NIGHT, the DUST
registration, the demanded token), the settlement, and the unwrap. Nothing here is
parallelisable — a wallet that submits twice before the first transaction confirms is rejected
outright (`1010: Custom error: 170`), which is why each funding step is retried rather than
pipelined.

The chain is re-runnable on a live stack: each run wraps fresh NIGHT and posts a new offer, and
the taker keeps the change from the previous run's demanded token.

## `SHIELDED_NIGHT_LOCK` — a one-way door

Setting it to `true` makes the one-shot run upstream's `deploy-and-lock.ts` instead of
`deploy.ts`: after deploying, it **dissolves the contract's maintenance committee** (empty
committee, threshold 1). No signature set can ever satisfy `committee < threshold` again, so no
verifier key and no rule can ever be changed. The circuits keep running; the contract simply
becomes permanently non-upgradeable.

It is **off by default and should stay off here.** It is meant for hosted releases — upstream's
live Preview contract is locked — and a throwaway devnet contract that dies with `./down.sh -v`
gains nothing from it. The knob exists because upstream's release path uses it.

`./verify.sh`'s on-chain-key check calls upstream's `scripts/verify-deployment.ts` with
`--allow-unlocked` (project 00007 phases F1/H2): the lock state is still measured and printed to
the `shielded-night-verify` container's log either way, but only the verifier-key/circuit-set
check decides the exit code — a devnet contract deliberately left unlocked (the default here)
no longer makes the strongest check in the profile read as a failure. This means `verify.sh` no
longer independently FAILS a bring-up where `SHIELDED_NIGHT_LOCK` was set but the contract
somehow came up unlocked (or vice versa); read the container's log line (`✓ LOCKED: …` / `ℹ NOT
locked: …`) if you need to confirm the authority state directly.

## Troubleshooting

| symptom | cause |
|---|---|
| the web container never becomes healthy, logs `waiting for /srv/shielded-night/contract.json` | the deploy one-shot has not finished (or failed). `docker compose … logs shielded-night-deploy`. |
| the one-shot exits 78 with `REFUSING to use the genesis-1 seed` | `SHIELDED_NIGHT_WALLET_SEED` was set to `0x…01`. That seed is the faucet, the offer-files deploy wallet and the kernel's. Use another. |
| the one-shot exits 78 with `missing required environment` | the fragment was rendered without `compose/shielded-night.yml`'s `environment:` block — usually a hand-built `docker compose` invocation rather than `./up.sh`. |
| the page loads but the network dropdown shows only *Preview* | `/config.js` was not served or carried no address. `curl http://127.0.0.1:${SHIELDED_NIGHT_HOST_PORT}/config.js`. |
| the page says the wallet does not support dApp proving | the connected wallet has no `getProvingProvider`. See `docs/KNOWN-LIMITATIONS.md`. |
| `verify.sh` reports the round trip failed on a wallet that never syncs | something else is holding a facade on the driver seed (`genesis-2` by default). Nothing in this repository does — check for a hand-started container or script of your own. See `docs/KNOWN-LIMITATIONS.md`. |
| the book subsection fails at step 0 with "the kernel's token registry does not name … sNight" | the `shielded-night-token-name` one-shot did not run (the profiles were brought up separately, so `up.sh` never saw both) or `ENABLE_TOKEN_REGISTRY` did not reach the kernel as the literal string `true`. Re-run `./up.sh --with offerfiles --with shielded-night`, or `docker compose … run --rm --no-deps shielded-night-token-name`. |
| the book subsection fails at step 4 with "no live offer gives …" | the offer expired (`TTL_MINUTES`, 120 by default) or a previous run already consumed it. Re-run the section; step 2 posts a fresh one each time. |
| the book subsection fails with `1010: Invalid Transaction: Custom error: 170` after every retry | the funder wallet is submitting faster than the chain confirms. It is retried 8 times, 15 s apart; if it still fails, the node is not producing blocks — check `docker compose … logs node`. |
