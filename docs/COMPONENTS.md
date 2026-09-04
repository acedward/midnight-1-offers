# Components

> **Scope.** This file documents the source pins that decide which LINE the stack runs, the
> **`solver`** profile's own processes, and the **`shielded-night`** profile. The component
> notes for `core`, `offerfiles` and `frontend` are still to be written; `README.md` remains the
> map of the stack.

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
