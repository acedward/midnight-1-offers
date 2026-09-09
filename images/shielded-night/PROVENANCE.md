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
follow-ups [#11](https://github.com/effectstream/shielded-night/pull/11) (filled in the PreProd
contract address in `frontend/.env`) and [#12](https://github.com/effectstream/shielded-night/pull/12)
("00007-lockfile-and-allow-unlocked", phase H2 re-pin: both `bun.lock` files regenerated wholesale
on bun 1.4.0, and `scripts/verify-deployment.ts` gained `--allow-unlocked`, which
`images/shielded-night/entrypoint-verify.sh`'s `verify_keys()` now calls instead of parsing the
script's stdout — see that file's own header comment). The earlier branch-head pin (`0b0a358`) is
retired: a branch head is a temporary identity — the branch can be force-pushed, and the pin would
then name bytes that exist on no branch at all.

### Re-pinned to `main` @ `2bb32838a` (00020 PR E) — three PRs, and what each cost this image

`SHIELDED_NIGHT_REF` moved from `f7fcefa7…` three first-parent merges on:
[#13](https://github.com/effectstream/shielded-night/pull/13) (multinetwork: Stagenet, a
`protocolFamily` per network, the isolated `frontend/protocols/{shared,v1,v2}` trees, and a
complete Midnight-2.x contract at `contracts/v2` compiled by compactc 0.34.0),
[#14](https://github.com/effectstream/shielded-night/pull/14) (proving-asset URLs resolved
against the page origin) and [#15](https://github.com/effectstream/shielded-night/pull/15)
(reverse conversion takes any sNight amount the wallet holds).

**Measured at the pin before anything was built, and this is the shape of the whole re-pin:**
`git diff --stat f7fcefa..2bb3283 -- src/ scripts/ test/support` is **EMPTY**. So
`src/shielded-night.compact` and the committed `src/managed/` are byte-identical to the previous
pin — the byte-exact rebuild target below did not move — and neither did
`scripts/verify-deployment.ts` (`--allow-unlocked`), `scripts/deploy-record.ts` (`DEPLOY_OUT`) or
any `test/support/*` primitive the deploy one-shot and `driver/snight-driver.ts` import. **Not one
existing assertion in this Dockerfile was falsified.** `frontend/bun.lock` is not in the diff at
all and the root `bun.lock` gained exactly one entry (matching one added `devDependencies` line),
so both `--frozen-lockfile` installs stay valid.

**#15 needed nothing here**, which is also a measurement rather than a hope: the change is
page-side (`frontend/src/lib/swap.ts`, the new `frontend/protocols/shared/coin-store.ts`), the
contract is unchanged, both round-trip test names `entrypoint-verify.sh roundtrip` selects still
exist verbatim, and this image's `driver/snight-driver.ts` `unwrap` mode already DISCOVERED its
coins instead of requiring one of an exact size.

**#13 cost the BUILD a stage** — see "Four dependency installs" below — **and made the v8-line
assertion grow.** **#14 moved the served proving-asset path**, which is the one runtime-visible
change: see "Where the page fetches its proving assets".

## The 1.x line, asserted rather than assumed

shielded-night is already on exactly this stack's line, which is why this profile needed no
porting: `@midnight-ntwrk/ledger-v8` 8.1.0 (pinned tree-wide through `overrides`, because two
ledger copies give two class identities and break `instanceof` during proving), midnight-js
4.1.1, compact-js 2.5.1, compact-runtime 0.16.0, dapp-connector-api 4.0.1 — against this
repository's node 1.0.1 / indexer 4.3.3 / proof-server 8.1.0.

Nothing but a pin distinguishes that from the 2.x sibling's copy of this same profile, which
points at a ledger-v9 branch of the same repository. So the pin is checked: the exact v8
override and compact-runtime 0.16.0 must be present in **both** `package.json` files, and
`ledger-v9` must appear in neither them nor either **resolved lockfile** — the half a
`package.json` grep cannot see.

### Since upstream #13 the tree has TWO lanes, and the assertion says which one is ours

#13 split the browser side into isolated protocol trees — `frontend/protocols/v1`
(midnight-1.x) and `frontend/protocols/v2` (midnight-2.x) — each with its own
`package-lock.json`, precisely so the two Compact runtimes and their two WASM class identities
can never share a physical `node_modules`. **So ledger-v9 IS in the pinned tree now, on purpose**,
in exactly two places: `frontend/protocols/v2` and `contracts/v2` (measured: 2 + 4 and 2 + 12
hits at `2bb32838a`).

The old four-file check was therefore **still true and no longer sufficient** — it never looked
at `frontend/protocols/v1`, the tree that now actually builds the adapter this stack's page runs.
Six files are checked for the `"@midnightntwrk/ledger-v9"` key now, and `protocols/v1` is checked
in the **positive** direction as well (ledger-v8 8.1.0 **and** compact-runtime 0.16.0 in both its
`package.json` and its `package-lock.json`), because "no v9" and "the v8 this stack runs" are
different claims and a tree with neither would satisfy the first.

`frontend/protocols/v2` and `contracts/v2` are deliberately **not** in that list. They are the
2.x lane; nothing on `undeployed` can select them, and being a separate resolution root is their
whole purpose. Asserting v9's absence there would fail a correct tree, and asserting its presence
would pin an upstream implementation detail this stack does not depend on.

### The protocol this stack's page selects, asserted at its source

`frontend/src/lib/networks.ts` now gives every network a `protocolFamily`, and
`frontend/src/hooks/useShieldedNight.ts` branches on exactly that field, dynamic-importing
`protocols/v1/src/adapter` for `midnight-1.x` and `protocols/v2/src/adapter` otherwise.
**`undeployed` is `midnight-1.x` upstream**, so this stack runs the ledger-v8 adapter by
upstream's own table rather than by an arrangement of ours — which is why the build asserts that
one line rather than assuming it. A re-pin that moved `undeployed` to `midnight-2.x` would
otherwise produce a page that loads, offers *Local (undeployed)*, and then dials a ledger-v9
adapter at an 8.1.0 chain: a failure with no plausible cause anywhere near the pin.

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

**There are TWO Compact toolchains left in this stack, and this is one of them.** This paragraph
named three until 00020 — the kernel image at 0.30.0, `images/zswap-da` at 0.31.0 and this image
at 0.31.1 — and both of the others are **gone**: kernel
[#69](https://github.com/effectstream/zswap-offerfiles-kernel/pull/69) and effectstream
[#922](https://github.com/effectstream/effectstream/pull/922) deleted the offer-files contract
from both ends, so neither image compiles anything and `toolchains[compact]` was removed from the
matrix (00020 PRs C and D). What remains is `compact-shielded-night` (0.31.1, this contract) and
`compact-issuer` (0.31.1, the issuer's three v1 token contracts — the same release assets, so the
same two SHA-256s). Each side's generated bindings are version-checked against its own
`compact-runtime` at import time, so they are not interchangeable;
`scripts/lib/compose_pins.py` binds each service's `COMPACT_VERSION` to its own matrix entry
rather than to a single shared one, and since 00020 PR D an unmapped service FAILS BY NAME rather
than being checked against some other image's compiler.

**And upstream #13 added a compiler this image deliberately does NOT pin.** `contracts/v2` is a
complete Midnight-2.x contract with committed artifacts built by compactc **0.34.0**, and its own
upstream CI job proves those byte-exact. This image does not compile it and does not pin 0.34.0:
`undeployed` is the `midnight-1.x` family, so nothing on this stack can deploy that contract,
prove against it, or fetch its keys — and this repository just went from four Compact compilers
to two. The v2 artifacts reach `dist` straight from the pinned tree (immutable by the 40-hex
commit; nothing in this build writes under `contracts/`), and the build asserts they were
EMITTED, which is the failure mode that can actually happen locally: a vite copy target silently
dropped by a re-pin. Recorded as question Q11 of project 00020, with the option table.

## Two runtime targets from one build

| target | base | what it is |
|---|---|---|
| `web` | `nginx:1.27-alpine` (digest-pinned) | the built SPA on container `:10900`, plus the compiled contract artifacts the page fetches — under **`/contract/v1/shielded-night/`** since upstream #14, with `/contract/v2/` and the pre-#14 `/contract/compiled/` served alongside (see below). `entrypoint-web.sh` waits for the deploy one-shot's `contract.json` and writes `/config.js`. |
| `deploy` | `oven/bun:1.4.0` (digest-pinned) | the pinned tree and its **root** `node_modules`, for `entrypoint-deploy.sh` (deploy once per stack) and `entrypoint-verify.sh` (on-chain keys + the round trips). No SPA, no frontend `node_modules`. |

**`build` and `deploy` are on bun 1.4.0, NOT the 1.3.11 the kernel and zswap-da images share (phase G,
plan question Q13).** `BUN_BASE` moved to 1.4.0 in phase G, BEFORE `SHIELDED_NIGHT_REF` needed it:
at that point the pinned tree (`main` @ `6d87db4`, pre-#12) still carried `lockfileVersion: 1`
lockfiles, which bun 1.4.0 reads without complaint (measured, both root and `frontend/`) — so moving
the base image ahead of the SHA that made it strictly necessary cost nothing. **Phase H2's re-pin
to `main` after #12 is the commit that makes it load-bearing**: #12 regenerated both `bun.lock`
files wholesale on bun 1.4.0 (Q11 -> A), and bun 1.4 writes `"lockfileVersion": 2`, a format bun
1.3.11 cannot read at all — `bun install --frozen-lockfile` would fail immediately with `error:
Unknown lockfile version` rather than resolve a stale dependency. This image is the ONLY one in
this repository on bun 1.4: the kernel's deploy entrypoint and zswap-da's build both stay on
1.3.11, which is load-bearing there (bun 1.3.14+ breaks the kernel's `midnight-contract:deploy`
with a graphql-tag/ESM `require()` error) and is unrelated to this tree's lockfile format.

## Four dependency installs, and why one of them needs a node stage

The root and `frontend` dependency sets are installed in the `build` stage with
`--frozen-lockfile`, and both are installed **deliberately**: the frontend imports the compiled
contract from `../src/managed`, outside its own package root, so Rollup would resolve the
WASM-bearing midnight packages for those files from the ROOT `node_modules` — a second physical
copy whose classes fail the app's `instanceof` checks. `vite.config.ts`'s `resolve.dedupe` is the
fix, and it is only exercised when both installs are present. Installing only the frontend's
would make the build pass while testing nothing. This is upstream's own CI reasoning, reproduced
here.

**Since upstream #13 there are FOUR**, and upstream's own CI comment gives the reason in one
sentence: *"Every install matters. The v1/v2 package trees intentionally carry separate WASM
class identities; vite.config.ts routes each generated contract import through its matching
profile runtime."* `vite.config.ts`'s new `profileRuntimeResolution()` plugin resolves every
`@midnight-ntwrk/compact-runtime` import made from `src/managed/` to
`frontend/protocols/v1/node_modules/@midnight-ntwrk/compact-runtime/dist/index.js`, and every one
made from `contracts/v2/managed/` to the v2 tree's copy. Both adapters are bundled even though
only one ever runs: `useShieldedNight.ts` reaches them through `await
import('../../protocols/v{1,2}/src/adapter')` with a **static** string, which Rollup resolves at
build time into two chunks — and `frontend/tsconfig.json` now includes `protocols/*/src`,
`protocols/shared` and `../contracts/v2/managed/contract/index.d.ts`, so the frontend *typecheck*
needs them too.

Those two trees carry `package-lock.json`, not a bun lockfile, and upstream installs them with
`npm ci`. **Measured: `oven/bun:1.4.0` ships a `node` fallback binary and NO npm at all.** Hence
a separate `protocols` stage on the `node:24.15.0-trixie` digest `images/issuer` already pins —
one fewer distinct external identity in this repository, and one already vetted. `bun install`
would not be a substitute: it would re-resolve from `package.json` and migrate the npm lockfile,
discarding the exact pinned set that *is* the isolation. The stage asserts each tree resolved
`compact-runtime/dist/index.js` at the precise path the plugin hands Rollup, and that the two are
**different** builds (identical bytes would mean the isolation had collapsed). Nothing from the
stage reaches a runtime target: only the two `node_modules` trees are copied into `build`.
Upstream does not install `contracts/v2` for its frontend job, and neither does this image.

## What the built bundle is checked for

A build-stage grep of the *source* proves the code was written; it does not prove it survived
bundling, tree-shaking and minification. So the emitted assets are grepped for the literal
`SHIELDED_NIGHT` — a property name on `window`, which minifiers cannot rename and which
upstream documents as exactly this marker. Without it, `/config.js` would be written, served,
and ignored, and the page would offer no "Local (undeployed)" network at all.

**Two more markers since #13, by the same argument:** the string literals `midnight-1.x` and
`Local (undeployed)`. Minification preserves string literals verbatim, so finding both in the
emitted assets is what proves the multinetwork table — the thing that decides which adapter this
stack's page loads — was actually shipped, rather than merely present in the tree the source
stage grepped. `scripts/verify-shielded-night.sh` then reads the same two out of the **served**
javascript, which is a third, independent claim: that this container is serving that build.

## Where the page fetches its proving assets

Upstream #14's `frontend/protocols/shared/asset-url.ts` resolves the tree as
`<page origin>` + the vite base + `contract/<profile>/shielded-night`, and the v1 adapter passes
the result to `FetchZkConfigProvider`. **So on this stack the live path is
`/contract/v1/shielded-night/`** — `undeployed` is the `midnight-1.x` profile. (#14 exists
because the #13 adapters passed a RELATIVE `'./contract/v1/shielded-night'` straight in, and the
SDK validates its base with a bare `new URL(baseURL)`: pressing *Connect wallet* threw
`Failed to construct 'URL': Invalid URL` before any network work started.)

`vite.config.ts` emits **three** trees and this image serves all three: `contract/v1` and
`contract/v2` from the two managed directories, plus `contract/compiled` — the pre-#14 path,
which upstream keeps for clients left open across a rollout. The build asserts all three carry
their 11 verifier keys, that `contract/v1` holds byte-for-byte the keys THIS build compiled, and
that `contract/v1` and `contract/v2` are not the same tree copied twice (a count alone cannot
tell those apart, since both contracts have 11 circuits with identical names).

`nginx.conf`'s `try_files $uri =404` artifact lane covers all three with one regex location. That
is not tidying: left as a prefix block on `contract/compiled/` alone, a **miss** under
`contract/v1/` would have fallen into the SPA fallback and answered 200 with the app shell —
`FetchZkConfigProvider` checks only `response.ok`, so the prover would be handed an HTML document
as a proving key, and the failure would surface deep inside proving naming none of this.

## A note on what else the page offers

The upstream tree's committed `frontend/.env` carries the live **Preview**, **Preprod** and —
since #13 — **Stagenet** contract addresses, so the built page's network menu offers all three
alongside *Local (undeployed)*. That is upstream's file, unmodified: this image adds a network,
it does not remove one. **Only *Local (undeployed)* has anything to do with this stack**, and it
is the only network `/config.js` injects an address for; the other three talk to public networks
through your wallet, and Stagenet additionally runs the ledger-v9 adapter, which nothing in this
1.x stack provides or needs. #13 also changed what an UNSET address means: the three public
networks now stay visible and are presented as unavailable rather than being hidden.

## Licenses

The upstream repository ships no `LICENSE` file at the pinned commit, so none is copied. This
file is installed at `/usr/share/licenses/shielded-night/PROVENANCE.md` in the `web` image.
