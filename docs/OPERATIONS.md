# Operations

> **Scope.** This file currently documents the **`shielded-night`** profile only. Operating
> notes for the other profiles land with 00005 P6.

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
| `SHIELDED_NIGHT_DRIVER_SEED` | the `lace-test` seed | the verify round trip's wallet; must differ from the deployer's |
| `SHIELDED_NIGHT_NAME` / `_SYMBOL` / `_DECIMALS` | `Shielded Night` / `sNight` / `6` | sealed into the contract at deploy; they cannot be changed afterwards |
| `SHIELDED_NIGHT_LOCK` | `false` | see below |
| `SHIELDED_NIGHT_WAIT_TIMEOUT` | `600` | how long the web container waits for `contract.json` before failing |

## `SHIELDED_NIGHT_LOCK` — a one-way door

Setting it to `true` makes the one-shot run upstream's `deploy-and-lock.ts` instead of
`deploy.ts`: after deploying, it **dissolves the contract's maintenance committee** (empty
committee, threshold 1). No signature set can ever satisfy `committee < threshold` again, so no
verifier key and no rule can ever be changed. The circuits keep running; the contract simply
becomes permanently non-upgradeable.

It is **off by default and should stay off here.** It is meant for hosted releases — upstream's
live Preview contract is locked — and a throwaway devnet contract that dies with `./down.sh -v`
gains nothing from it. The knob exists because upstream's release path uses it, and because
`./verify.sh` asserts the authority state **in both directions**: it fails if the contract is
locked when nobody asked for it, which is the only way to notice that a one-way door was walked
through by accident.

## Troubleshooting

| symptom | cause |
|---|---|
| the web container never becomes healthy, logs `waiting for /srv/shielded-night/contract.json` | the deploy one-shot has not finished (or failed). `docker compose … logs shielded-night-deploy`. |
| the one-shot exits 78 with `REFUSING to use the genesis-1 seed` | `SHIELDED_NIGHT_WALLET_SEED` was set to `0x…01`. That seed is the faucet, the offer-files deploy wallet and the kernel's. Use another. |
| the one-shot exits 78 with `missing required environment` | the fragment was rendered without `compose/shielded-night.yml`'s `environment:` block — usually a hand-built `docker compose` invocation rather than `./up.sh`. |
| the page loads but the network dropdown shows only *Preview* | `/config.js` was not served or carried no address. `curl http://127.0.0.1:${SHIELDED_NIGHT_HOST_PORT}/config.js`. |
| the page says the wallet does not support dApp proving | the connected wallet has no `getProvingProvider`. See `docs/KNOWN-LIMITATIONS.md`. |
| `verify.sh` reports the round trip failed on a wallet that never syncs | something else is holding a facade on the driver seed — most often a Lace session on `lace-test`. See `docs/KNOWN-LIMITATIONS.md`. |
