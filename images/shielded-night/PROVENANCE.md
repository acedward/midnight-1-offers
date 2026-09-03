# Shielded NIGHT build provenance

## Where the source comes from

The image fetches [`effectstream/shielded-night`](https://github.com/effectstream/shielded-night)
whole, at the immutable commit recorded as `sources[shielded-night].ref` in
`config/artifact-decisions.json` and passed in as `SHIELDED_NIGHT_REF`. The build refuses
anything that is not a full 40-character lowercase-hex commit, `git fetch --depth 1 origin
<sha>` cannot resolve a branch, and the resolved commit is baked into BOTH runtime images as
`/.shielded-night-commit` — so "what is in here?" is answerable from a running stack rather
than from remembering how it was built. `scripts/verify-source-pins.sh` reads it back out of
each image and asserts it against the matrix.

No dApp source and no generated `managed/` output is stored in this repository.

## What is NOT applied: any patch at all

This image carries **no patch of any kind**, and that is a decision with a paper trail
(project 00007, question Q2, owner decision A). A compose-hosted deployment of this dApp needs
three things the upstream repository did not originally have:

1. a **runtime contract-address override** — the address is otherwise a build-time input
   (`<NETWORK>_ADDRESS` through vite's `envPrefix`), and this image is built once and run
   against throwaway devnets whose contract does not exist until the deploy one-shot runs;
2. **env-overridable `undeployed` endpoint URLs** — the defaults are `127.0.0.1`, which inside
   a container means "nothing is there"; a deploy running on the compose network must dial
   `node:9944` / `indexer:8088` / `proof-server:6300`;
3. an **external-stack mode** for the integration suite — it otherwise brings up its own
   testcontainers devnet, and the point of the gate is to prove the contract on *this* stack.

…plus the `/config.js` **placeholder and its `<script>` tag**, so that even the built output
needs no editing: upstream ships `frontend/public/config.js` (a no-op that only ensures the
global exists) and references it from `index.html` as a classic script, and this image simply
overwrites that one already-served file at container start.

All of it lives upstream, because `effectstream/shielded-night` is a first-party repository. The
build **asserts each of them is present in the pinned tree** — `frontend/src/lib/runtime-config.ts`
and its use in `networks.ts`, the four `MN_*_URL` names in `test/support/network.ts`,
`MN_EXTERNAL_STACK` in `test/integration/global-setup.ts`, `DEPLOY_OUT` in
`scripts/deploy-record.ts`, and both the `public/config.js` placeholder and the tag that loads
it (checked in the source tree and again in the built `dist/`) — so a re-pin to a tree without
them fails the build instead of producing a page that can never learn its address.

### The pin is a commit on `main`

Those changes are [`effectstream/shielded-night#9`](https://github.com/effectstream/shielded-night/pull/9),
merged upstream on 2026-09-03 (`5902a90`). `SHIELDED_NIGHT_REF` is `main`'s head after the
follow-up [#11](https://github.com/effectstream/shielded-night/pull/11), which filled in the
PreProd contract address in `frontend/.env`. The earlier branch-head pin (`0b0a358`) is retired:
a branch head is a temporary identity — the branch can be force-pushed, and the pin would then
name bytes that exist on no branch at all.

## The 1.x line, asserted rather than assumed

shielded-night is already on exactly this stack's line, which is why this profile needed no
porting: `@midnight-ntwrk/ledger-v8` 8.1.0 (pinned tree-wide through `overrides`, because two
ledger copies give two class identities and break `instanceof` during proving), midnight-js
4.1.1, compact-js 2.5.1, compact-runtime 0.16.0, dapp-connector-api 4.0.1 — against this
repository's node 1.0.0 / indexer 4.3.3 / proof-server 8.1.0.

Nothing but a pin distinguishes that from the 2.x sibling's copy of this same profile, which
points at a ledger-v9 branch of the same repository. So the pin is checked: the exact v8
override and compact-runtime 0.16.0 must be present in **both** `package.json` files, and
`ledger-v9` must appear in neither them nor either **resolved lockfile** — the half a
`package.json` grep cannot see.

## The contract, and the compiler that compiles it

`src/shielded-night.compact` is recompiled in the image with **compactc 0.31.1**, fetched as a
release asset and SHA-256-verified per architecture (the hashes come from the GitHub release
API's own `digest` field and are recorded as `toolchains[compact-shielded-night]` in
`config/artifact-decisions.json`), never resolved through the `compact` version manager whose
lookup cannot be pinned.

0.31.1 is not this repository's choice: the pinned tree's `package.json` runs
`compact compile +0.31.1` and its CI pins the same version. The build asserts that line still
says so, so the ARG and the source cannot drift apart silently.

The compile happens into an **empty** directory and its output is then `diff -r`'d against the
tree's committed `src/managed/`. **Any difference fails the build.** That byte-exactness is the
dApp's entire verifiability claim — the deployed contract's on-chain verifier keys are the ones
compiled from this source, which `scripts/verify-shielded-night.sh` then checks against the
chain — and upstream's own `reproducible-build` CI job proves it on every push. This image
reproduces the proof locally rather than trusting it (project 00007, question Q3, owner
decision A).

**There are three Compact toolchains in this stack, on purpose.** The kernel image compiles the
offer-files contract with 0.30.0, `images/zswap-da` compiles the template's copy of that same
source with 0.31.0, and this image compiles an entirely different contract with 0.31.1. Each
side's generated bindings are version-checked against its own `compact-runtime` at import time,
so they are not interchangeable. `scripts/lib/compose_pins.py` binds each service's
`COMPACT_VERSION` to its own matrix entry rather than to a single shared one.

## Two runtime targets from one build

| target | base | what it is |
|---|---|---|
| `web` | `nginx:1.27-alpine` (digest-pinned) | the built SPA on container `:10900`, plus the compiled contract artifacts under `/contract/compiled/shielded-night/`. `entrypoint-web.sh` waits for the deploy one-shot's `contract.json` and writes `/config.js`. |
| `deploy` | `oven/bun:1.3.11` (digest-pinned) | the pinned tree and its **root** `node_modules`, for `entrypoint-deploy.sh` (deploy once per stack) and `entrypoint-verify.sh` (on-chain keys + the round trips). No SPA, no frontend `node_modules`. |

Both dependency sets are installed in the build stage with `--frozen-lockfile`, and both are
installed **deliberately**: the frontend imports the compiled contract from `../src/managed`,
outside its own package root, so Rollup would resolve the WASM-bearing midnight packages for
those files from the ROOT `node_modules` — a second physical copy whose classes fail the app's
`instanceof` checks. `vite.config.ts`'s `resolve.dedupe` is the fix, and it is only exercised
when both installs are present. Installing only the frontend's would make the build pass while
testing nothing. This is upstream's own CI reasoning, reproduced here.

## What the built bundle is checked for

A build-stage grep of the *source* proves the code was written; it does not prove it survived
bundling, tree-shaking and minification. So the emitted assets are grepped for the literal
`SHIELDED_NIGHT` — a property name on `window`, which minifiers cannot rename and which
upstream documents as exactly this marker. Without it, `/config.js` would be written, served,
and ignored, and the page would offer no "Local (undeployed)" network at all. The 11 circuits'
artifacts are also asserted present under `dist/contract/compiled/shielded-night/`.

## A note on what else the page offers

The upstream tree's committed `frontend/.env` carries the live **Preview** and **PreProd**
contract addresses, so the built page's network dropdown offers both alongside *Local
(undeployed)*. That is upstream's file, unmodified: this image adds a network, it does not
remove one. Only *Local (undeployed)* has anything to do with this stack; the other two talk to
the public networks through your wallet.

## Licenses

The upstream repository ships no `LICENSE` file at the pinned commit, so none is copied. This
file is installed at `/usr/share/licenses/shielded-night/PROVENANCE.md` in the `web` image.
