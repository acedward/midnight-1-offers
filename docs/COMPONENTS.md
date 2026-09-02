# Components

> **Scope.** This file currently documents the **`shielded-night`** profile only. The
> component notes for `core`, `offerfiles`, `frontend` and `solver` land with 00005 P6; this
> is the first section of that document, not a whole-stack reference. `README.md` remains the
> map of the stack.

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

### What else the page offers

Upstream's committed `frontend/.env` carries the live **Preview** contract address, so the
network dropdown shows *Preview* alongside *Local (undeployed)*. That is upstream's file,
unmodified — this profile adds a network rather than removing one. Only *Local (undeployed)*
has anything to do with this stack.
