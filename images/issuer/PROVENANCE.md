# `images/issuer` — provenance

**What this image is.** The `issuer` profile's two runtime targets, built from the **public**
[`effectstream/mint-test-tokens`](https://github.com/effectstream/mint-test-tokens) repository at
one immutable full commit:

| target | base | what it is |
|---|---|---|
| `runtime` | `node:24.15.0-trixie-slim` (index digest pinned) | the pinned tree + its **root** `node_modules` + its `.git` + `git` + `psql`. Four roles, one per entrypoint: `issuer-deploy`, `issuer-registrar`, `issuer-fund`, `issuer-registry`. |
| `faucet` | `nginx:1.27-alpine` (index digest pinned — the same one `images/zswap-da` and `images/shielded-night` use) | nginx serving the repository's built `frontend/dist` on container `:10500`, with this stack's own registry mounted in from the `issuer-registry` volume. |

**Nothing upstream is committed here.** No dApp source, no generated `managed/` artifact, no
`dist`. A cold build needs GitHub + npm network access. What IS committed here is the
integration layer: the Dockerfile and its assertions, four entrypoints, one nginx config, one
SQL file and four small TypeScript files under `m1/`.

## The pin

`ISSUER_REF` is a full 40-hex commit and is stated in exactly three places, all of which
`scripts/verify-artifact-decisions.sh` and `scripts/verify-compose-pins.sh` cross-check:
`.env.example`, `scripts/lib/common.sh` (the script-side default), `scripts/pick-ports.sh` (the
generated `.env`), the `build.args` default in `compose/issuer.yml`, the `ARG` default in this
image's Dockerfile, and `config/artifact-decisions.json` (`sources[issuer]`). `git fetch
--depth 1 origin <sha>` refuses an abbreviated sha and cannot follow a branch move, which is the
cheapest possible enforcement of the pinning rule; the stage then asserts
`git rev-parse FETCH_HEAD` equals the pin.

`COMPACT_VERSION` is **0.31.1** and is *not* an operator knob. The pinned tree states that
compiler in three independent places — `compatibility.json`'s v1 profile, `scripts/v1-deploy.ts`'s
`EMBEDDED_COMPILER_VERSION`, and each `contracts/v1/managed/*/compiler/contract-info.json` — and
the build asserts all three. It is the same compiler `images/shielded-night` pins, from the same
release, so `config/artifact-decisions.json`'s `toolchains[compact-issuer]` carries the **same two
asset SHA-256s** as `toolchains[compact-shielded-night]`.

## The `.git` directory is part of the runtime, not an accident

`scripts/lib/deployment-provenance.ts` in the pinned tree runs `git rev-parse HEAD`,
`git cat-file -e <rev>:<path>`, `git diff --name-only <rev> -- <paths>` and both
`git ls-files --others` variants over

```
contracts/v1/shielded-token.compact
contracts/v1/unshielded-token.compact
contracts/v1/managed/shielded
contracts/v1/managed/unshielded
```

**before it will submit a deployment**, and records the resolved commit in every registry record
as `artifact.sourceRevision`. A runtime image without a git repository at the pin cannot issue a
token at all. That is a feature — the registry this stack publishes names the exact source
revision its verifier keys came from — so the image keeps `.git`, detached exactly at
`ISSUER_REF`, writes nothing under `contracts/`, and puts `/m1/` in `.git/info/exclude` rather
than in the tree's own `.gitignore` (editing that would make `git diff <pin>` non-empty and
refuse every deployment). The Dockerfile then runs those exact four checks at BUILD time, so an
image that could not deploy fails in seconds instead of mid-bring-up.

The frontend build needs two MORE commits: `verify-client-artifacts.mjs` hashes
`contracts/{v1,v2}/managed/*` from the Git objects of the revisions named in
`frontend/client-artifacts.json` and refuses to build if they are missing. Those revisions are
**read out of that file** and fetched shallowly, rather than pinned a second time here — a second
copy could disagree with the manifest the verifier actually reads.

## The byte-exact recompile

All three v1 contracts are recompiled with compactc 0.31.1 and the result must be
**byte-identical** to the committed `contracts/v1/managed/`:

| contract | circuits | measured compile time (this host, 2026-09-08) |
|---|---|---|
| `contracts/v1/shielded-token.compact` | 5 — `name symbol decimals tokenColor mint` | 17 s |
| `contracts/v1/unshielded-token.compact` | 5 — same set | 8 s |
| `contracts/v1/receiver.compact` | 9 | 88 s |

`receiver` is compiled too, even though the deploy runner never instantiates it: the faucet site
serves its proving keys to the browser for a contract-recipient mint, so its keys are as
load-bearing as the issuers'.

**The invocation matters.** compactc records the input path it was given, verbatim, in the emitted
source map. The committed map says `"sourceRoot": "../../../../../"` and
`"sources": ["contracts/v1/shielded-token.compact", …]`, so the compile must run **from the
repository root** as `compactc contracts/v1/<name>.compact contracts/v1/managed/<name>/`. Any
other cwd or path spelling produces artifacts that are byte-identical in every ZK key and differ
in two lines of the map — which would force the assertion to be loosened to "everything except
the source map". `images/shielded-night` learned this the expensive way; this image inherits the
lesson.

**Unlike `images/shielded-night`, the freshly compiled bytes are NOT copied forward.** That image
ships what it compiled so that "what the page serves" and "what this build compiled" are the same
bytes by construction. Here the opposite is required: the deploy runner re-hashes
`contracts/v1/managed/` and records the digest as provenance, and refuses on any working-tree
difference from the pinned commit — so the COMMITTED bytes must be the ones that ship. The
equality is proven instead, which is the same guarantee reached from the other side. The `compact`
stage therefore hands the `build` stage a one-line marker file, `/verified/COMPACT-OK`, purely so
that BuildKit keeps the stage in the graph; without that `COPY` the proof would be a stage nothing
asks for and BuildKit would never run it.

## The v8 / v1 line, asserted — and the v2 lane, asserted to be SEPARATE

This repository's core is node 1.0.1 / indexer 4.3.3 / proof-server 8.1.0: the ledger-v8 line.
Two ledger wasm instances in one dependency graph fail `instanceof` during proving, hours later
and nowhere near the cause, so the ROOT graph (which is what the `runtime` target ships) and
`frontend/protocols/v1` are both asserted to carry `@midnight-ntwrk/ledger-v8` 8.1.0,
`compact-runtime` 0.16.0 and **no** `@midnightntwrk/ledger-v9` key.

`frontend/protocols/v2` *does* depend on ledger-v9, and that is correct and must not be "fixed":
upstream installs the three browser profiles as isolated package roots with their own lockfiles
precisely so the 1.x and 2.x graphs are never deduplicated into one incompatible runtime
(`frontend/README.md` says so). The build asserts that isolation still exists — its own
`package.json` **and** its own `package-lock.json` — rather than asserting the dependency is
absent.

## What the build asserts about the pinned tree, and why each assertion exists

| assertion | the failure it prevents |
|---|---|
| the five `MN_*` endpoint variables are still read by `scripts/lib/network-config.ts` | a one-shot that silently dials `127.0.0.1` inside a container and times out |
| `MN_SEED_FILE` is still the only way in, and `wallet-seed.ts` still demands 32/64 bytes of hex | a seed on a command line, visible in `docker inspect` |
| `MN_METADATA_OUTPUT_DIR` and `metadataOutputPath()` still exist | a registry written where nothing looks for it |
| `MN_REDEPLOY_STALE`, `MN_CONFIRM_NO_DEPLOYMENT` and `markRegistryStale` still exist | a chain reset that silently redeploys, or stale ids posted to the kernel |
| `export circuit mint` with a `Uint<64>` in both issuer contracts | a faucet that can only hand out fixed presets, so no automation can size a coin |
| `additionalCoinEncPublicKeyMappings` is still used by the runner | a third-party shielded mint the recipient's wallet can never discover |
| the six symbols with their exact names, decimals and privacy | every price and every mint amount in the stack is scaled by `decimals`; a silent 8→9 is wrong by a factor of ten |
| `frontend/public/_headers` matches a pinned SHA-256 | `images/issuer/nginx.conf` describing a header policy upstream no longer has |
| `dist` carries no `metadata.undeployed.json`, and does carry both issuers' `mint` keys and the receiver's | a baked registry naming contracts that do not exist on this chain; a proving key served as the SPA shell |
| the four git provenance checks, at build time | an image that cannot deploy, discovered mid-bring-up |

## What is first-party, and what it does not do

`m1/` holds four small TypeScript files. None of them reimplements a contract, a registry
format, an endpoint default or a token definition — every one of those is imported from the
pinned tree (`scripts/lib/network-config.js`, `scripts/lib/wallet-seed.js`,
`packages/registry/src/{tokens,semantic,types}.js`, `contracts/v1/managed/*`). They exist for the
three things upstream has no reason to ship, because they only exist for a compose-hosted
throwaway devnet:

* **`m1/provision.ts`** — fund the issuer wallet from the chain's genesis wallet and register
  that NIGHT for DUST. The dust-registration recipe is upstream's own, read out of the published
  `@effectstream/midnight-contracts@0.103.1` (`src/get-wallet-info.ts`, `registerNightForDust`)
  and re-expressed against `@midnight-ntwrk/wallet-sdk-facade`'s
  `registerNightUtxosForDustGeneration`, which mint-test-tokens already installs. It is NOT
  imported from that package: doing so would put a second ledger-v8 wasm instance in this image's
  graph.
* **`m1/fund.ts`** — mint an exact, caller-chosen amount of one named token to one wallet, and
  read the recipient's balance back. Upstream's `scripts/v1-mint-wallet-test.ts` is the code
  pattern; it is a round-trip test, not a funding tool (fixed presets, all six tokens, a
  repository-local registry path, and it spends the coin back).
* **`m1/registry.ts`** — validate and dump THIS stack's `undeployed` registry, with the tree's
  own schema **and** its own semantic validator. Upstream's `npm run check` deliberately
  validates only the three tracked public registries.
* **`m1/lib.ts`** — the shared layer: endpoints, facades, the DUST helpers, and the one place the
  kernel's token NAME is derived from the registry's SYMBOL (`toUpperCase()`, and nothing else,
  because that is exactly what the kernel does to whatever it is sent).

They live at `/app/m1` — **inside** the pinned tree — because node resolves a bare specifier by
walking up from the importing file. Anywhere else, `@midnight-ntwrk/*` would not resolve.

## `sql/issuer-registry-patch.sql`

The 00015 sNight patch (organizer `issues/00012`) generalised from one hard-coded name to a
parameter, because kernel #69 turned a one-row problem into a six-row one. Read the file: it
carries the kernel's own instruction, quoted, the reason `POST /v1/known-tokens` cannot do the
job (`name` is UNIQUE and is checked before the colour), the reason it is correct on a kernel
that seeds nothing, and the reason it deliberately leaves `canonical_token_registry_state` alone.

## Devnet only

Every seed this image uses is a public value from `wallets/wallets.json`. `MN_NETWORK` is
asserted to be `undeployed` in every entrypoint that touches a chain, and the refusal explains
why: pointing this at Preview or Preprod would deploy six issuer contracts on a network where the
canonical ones are already live, paid for with a publicly known key.
