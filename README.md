# midnight-1-offers

A one-command **Midnight 1.x** demo stack: a local devnet (midnight-node 1.0.0, indexer
4.3.3, proof server 8.1.0), a Celestia DA devnet, the **offer-files kernel** and its batcher,
the **zswap-da** trading SPA, and the **Midnight Intents relay + COW solver** settling real
intents against the offer book.

It is the 1.x sibling of [`midnight-2-offers`](https://github.com/acedward/midnight-2-offers)
and follows the same operating model — compose profile fragments, `./up.sh --with <profile>`,
`./down.sh -v`, `./verify.sh`, every external artifact pinned by digest or full commit SHA,
every published port loopback-bound and parameterizable.

Two deltas beyond the version line:

- **dropped**: the AA profile (aa-contracts, AA console, experimental proof server) and the
  EVM profile — neither exists here.
- **added**: the real Midnight Intents relay and its browser UI, with the COW solver in
  **execution mode** settling relay intents against the kernel book. `midnight-2-offers`
  deliberately stopped at an observation-only sink; this repository runs the whole lane.

> **STATUS — scaffold.** Phase P0 (repository skeleton, operating scripts, pinned identities)
> is landed. The compose fragments are valid **placeholders**: they declare no services yet.
> Services and images arrive in P1 (core), P2 (offerfiles), P3 (frontend) and P4 (solver).
> `./up.sh` therefore brings up nothing today, and says so.

## Profiles

A profile **is** a compose fragment in `compose/`, named after the file. There are exactly
four, and `compose:` `profiles:` keys are never used anywhere in this repository — `up.sh`
never passes `--profile`, so a service carrying one would silently never start.

| Profile | Fragment | What it runs |
|---|---|---|
| `core` | `compose/core.yml` | midnight-node 1.0.0, indexer-standalone 4.3.3, proof-server 8.1.0 (+ its proof-data pre-warm), PostgreSQL with `pg_ivm`. **Unconditional** — every `up.sh` includes it. |
| `offerfiles` | `compose/offerfiles.yml` | Celestia DA devnet, the offer-files contract deploy one-shot, the kernel API (`:9999`) and the batcher (`:3334`), built from `effectstream/zswap-offerfiles-kernel` **main**. |
| `frontend` | `compose/frontend.yml` | the `zswap-da` SPA (`:10600`), built from the frozen `effectstream/effectstream` template — v8-native at that ref, so **no** ledger patch. |
| `solver` | `compose/solver.yml` | the Midnight Intents relay (`:13000` HTTP, `:19001` solver WS), the COW solver in execution mode, the provisioning one-shots, and the intents browser UI (`:10700`). |

```sh
./up.sh                                    # core alone
./up.sh --with offerfiles                  # …and Celestia + kernel + batcher
./up.sh --with offerfiles --with frontend  # …and the SPA
./up.sh --all                              # every profile
./verify.sh                                # assert the stack is usable, not merely running
./down.sh -v                               # stop and wipe every volume of this project
```

`--with` is additive: it never stops a profile that is already up. `--converge` is the
opposite and names everything it is about to stop before it does it.

## The `solver` profile builds from a PRIVATE clone you provide

The relay and the intents UI come from **`shieldedtech/midnight-intents-swaps`**, which is a
**private** repository. This one is public, so their source is never fetched, vendored or
mirrored here. Instead:

- you clone the private repository yourself and point `RELAY_SOURCE_DIR` at your clone;
- `up.sh` verifies your clone is at the pinned commit and has a clean tree **before** any
  build starts, and fails with a clear message when the variable is unset;
- the build reads it as a named build context; the `Dockerfile`s committed here are our own
  transcriptions and contain no copied code;
- the resulting `midnight-1-offers/relay:local` and `…/intents-ui:local` images are **never**
  pushed to any registry.

Everything else — `core`, `offerfiles`, `frontend` — builds from public sources with no
credentials at all, so the repository degrades gracefully: without private access you get the
whole stack except the intents lane.

Two mechanisms keep this honest, and they run from day one:

- `.gitignore` ignores `local/`, the conventional place to put your clone inside the checkout,
  so it cannot be staged by accident;
- `./scripts/verify-no-private-source.sh` (wired into `scripts/ci-check.sh`) scans every
  tracked file and fails on private-source markers. It distinguishes *naming* the upstream —
  fine in Markdown, in `#` comments, and in the pinned identity in
  `config/artifact-decisions.json` — from *carrying* its content, which is never fine.
  Run it with `--self-test` to see every rule reject a synthetic leak.

## Everything external is pinned

No tags, no branch names, no "latest". Official images are pinned by **index digest**, source
builds by **full 40-hex commit SHA**, downloaded binaries by **SHA-256**. The single record is
[`config/artifact-decisions.json`](config/artifact-decisions.json), and three offline gates
keep it and the repository in agreement:

| Gate | Asserts |
|---|---|
| `./scripts/verify-artifact-decisions.sh --self-test` | the matrix is internally consistent, still makes the choices it froze, and its `pinsDigest` still covers every identity field |
| `./scripts/verify-compose-pins.sh --self-test` | the **rendered** compose configuration really asks for those bytes — no tag-only image, no forced `platform:`, no `profiles:` key, no drifted build arg |
| `./scripts/verify-source-pins.sh` | the images that are actually **running** were built from the configured commits (needs a live stack) |

All three are offline: no daemon, no network, no registry, no credential.

## Layout

```
compose/     core.yml, offerfiles.yml, frontend.yml, solver.yml — one fragment per profile
images/      build contexts for the locally built images (P1–P4)
scripts/     verify-*.sh gates, pick-ports.sh, ci-check.sh, lib/ (shared bash + python)
config/      artifact-decisions.json — the frozen pin record
docs/        component, operations, wallet and known-limitation notes (P6)
wallets/     wallets.json — the dev wallet roster (DEV SEEDS ONLY, no real funds)
local/       gitignored: where you put your own clone of the private relay source
up.sh down.sh verify.sh
.env.example copy to .env; the port block, seeds and pins live here
```

## Running two stacks side by side

Nothing hardcodes a cross-service port. Override the port block and
`COMPOSE_PROJECT_NAME` in a second env file and both stacks coexist:

```sh
./scripts/pick-ports.sh > .env.test     # a random free block above 10100 + a unique project
ENV_FILE=.env.test ./up.sh --all
ENV_FILE=.env.test ./down.sh -v
```

Defaults are the Midnight-standard ports (`9944` / `8088` / `6300`), because Lace's
`undeployed` preset hardcodes them.

## Scope and safety

- `undeployed` devnet only. **No real funds, ever.** Every seed in `wallets/wallets.json` is
  a public dev seed on a throwaway local chain; never reuse one anywhere else.
- The stack uses its own `COMPOSE_PROJECT_NAME` (default `midnight-1-offers`), so it cannot
  collide with a `midnight-2-offers` stack on the same machine.

## Licence

There is no `LICENSE` file, matching `midnight-2-offers`. This repository is published for
demonstration and review; no licence is granted by its being public. That is a deliberate,
recorded stance, not an oversight — if the sibling repository gains a licence, this one
follows it.
