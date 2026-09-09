# zswap-da frontend build provenance

## Where the source comes from

The image fetches `templates/zswap-da` directly from
[`effectstream/effectstream`](https://github.com/effectstream/effectstream) at the immutable
commit `400880ceb6814738d1ae193dae18ad5128922edc` — the head of the
[`midnight-1`](https://github.com/effectstream/effectstream/tree/midnight-1) branch, the line
maintained for midnight-node 1.x / ledger-v8 / `@effectstream` 0.1xx — whose template subtree
is `a750cccd653f33306d3ff7249fe8d5853fbfafa6`. BOTH identities are verified before checkout —
the commit alone does not prove which bytes of it were extracted — and the resolved commit is
recorded as `/.zswap-da-commit` inside the runtime image, so "what is in here?" never depends
on remembering which tag it was built as. No third-party SPA source is stored in this
repository. There is no generated contract output to commit either: since 00020 PR D this image
compiles nothing at all — see "The contract, and the compiler that used to compile it".

Upstream `templates/**` on `main` is FROZEN by effectstream 00016 FR-10, and `midnight-1` is
the 1.x line's own branch. Nothing here pushes to either; the pin is read-only.

### History of this pin (Q14)

The repository first pinned the frozen ref `332503c8` that midnight-2-offers also uses, and
found (measured at P3) that its template is v8-native in the CONTRACT lane but on the 2.x
line in the WALLET lane (`@effectstream/{midnight-contracts,wallets}` 0.200.1 → ledger-v9), so
the in-page wallet could not sync. It carried upstream's own reverse diff as
`effectstream-1x-line.patch`. The `midnight-1` branch forked upstream at `b267fa2e` (the
0.104.0 bump), BEFORE the 0.200.1 bump, so its template is natively on the 1.x line — and
its subtree is **byte-identical** to the patched frozen ref (`package.json` blob `822bd218…`,
`bun.lock` blob `1099e6f6…` on both sides). The owner chose to pin that branch and retire the
patch (2026-09-01).

## What is NOT applied: any ledger or dependency adaptation

The 2.x sibling repository (`midnight-2-offers`) carries a 55 KB `ledger-v9.patch` that
migrates this same template from ledger-v8 to ledger-v9. **This repository ships no such
patch and no such stage**, and since Q14 no dependency patch either: at this ref the template
is v8-native — `@midnight-ntwrk/ledger-v8` 8.1.0 and midnight-js 4.1.1;
`@effectstream/{midnight-contracts,wallets}` 0.104.0 (ledger-v8, wallet-sdk-facade 4.1.0) for
the wallet lane — which is exactly the line the 1.x kernel runs. That is asserted in the build
rather than assumed: the source stage requires `"@midnight-ntwrk/ledger-v8": "8.1.0"` and the
0.104.0 pair in `package.json`, refuses any `0.200.x` entry, and requires that no `ledger-v9`
appears anywhere in the resolved `bun.lock`. If the pinned ref ever drifts, the build fails
there instead of producing a silently mismatched bundle.

**One assertion of this set was RETIRED at `400880ce`, and it matters that it was retired rather
than relaxed.** The list used to include `"@midnight-ntwrk/compact-runtime": "0.16.0"` (and the
prose above used to name compact-js 2.5.1 beside it). effectstream #922 removed both packages
along with the contract lane they served, so keeping that grep would have failed a CORRECT tree.
It is replaced by the opposite assertion — `compact-runtime`/`compact-js` must NOT appear in
`package.json` — which is the same guard pointed the other way and catches the case that now
matters: a `FRONTEND_REF` moved backwards onto the contract line.

## What used to be applied, and is now upstream: the browser-network URIs

One function, `api.getMidnightConfig` in `src/services/api.ts`, was carried here as
`browser-network-urls.patch` until it landed on `midnight-1` as
[effectstream#912](https://github.com/effectstream/effectstream/pull/912) (merged 2026-09-02).
**This image now applies no patch of any kind.** It asserts the pinned tree carries the fix
(one marker per half, in the source and again in the emitted bundle) so a re-pin to a tree
without it fails the build. The description below is of that upstream change.

### Re-pin (00020 PR D) to the branch head after #920 and #922 — the contract lane goes

`FRONTEND_REF` moved to `400880ce` (from `58ab921`), subtree `a750cccd` (from `3ca1d56f`), two
first-parent merges on. **This is the FRONTEND HALF of kernel
[#69](https://github.com/effectstream/zswap-offerfiles-kernel/pull/69) and it moves together
with `KERNEL_REF`**, for the same reason #918 did: it is one change split across two
repositories.

[effectstream#922](https://github.com/effectstream/effectstream/pull/922) deletes the
template's whole contract lane. Verified against the tree rather than inferred from the PR
title: `git ls-tree -r 400880ce -- templates/zswap-da/src/contract` and
`… -- templates/zswap-da/scripts` are **both empty**. Gone with them: the
`build:contract` / `verify:contract` / `predev` / `prebuild` npm scripts,
`src/screens/Faucet.tsx`, `hooks/useContract.ts`, `hooks/useMintReconciler.ts`,
`services/contractWallet.ts`, `services/mintQueue.ts`, `api.registerKnownToken`, vite's
`zk-artifact-404` plugin, and the `@midnight-ntwrk/{compact-js,compact-runtime}` plus five
`midnight-js` contract-lane dependencies. `services/browserContract.ts` became
`services/browserOffers.ts`. `public/` now holds one file, `favicon.svg`.

[effectstream#920](https://github.com/effectstream/effectstream/pull/920) replaces the Faucet
TAB with a Faucet **LINK** (`src/ui/FaucetLink.tsx` + `src/faucetUrl.ts`) — a plain `<a>` that
needs no wallet and never probes the service — and adds two build-time knobs to
`src/config.ts`, `VITE_MIDNIGHT_NETWORK_ID` and `VITE_FAUCET_URL`. **Neither has a `window.*`
runtime override**, unlike `window.API_BASE` / `window.BATCHER_URL`, so both are build inputs of
this image (`FRONTEND_NETWORK_ID`, `FRONTEND_FAUCET_URL`; see 00020 Q4). #920 also **flipped
`VITE_MIDNIGHT_NETWORK_ID`'s default from `undeployed` to `preprod`**, and `useWallet.ts` and
`state/wallet.ts` now take the wallet-handshake network from that same constant — so an image
that sets none would format addresses, parse offers, call `initialApi.connect()` and build the
in-page JS wallet on the wrong network while looking entirely healthy.

Every other assertion in this file was re-measured against the new subtree BEFORE anything was
built, and all hold: `ledger-v8 8.1.0` present, `ledger-v9` absent from both `package.json` and
the resolved `bun.lock`, `@effectstream/{midnight-contracts,wallets} 0.104.0` with no `0.200.x`,
the #912 `pageHost` / `'proofServerUri'` markers still in `src/services/api.ts`, and both
LICENSE files. The one that did NOT hold, `compact-runtime 0.16.0`, is described above.

**The lockfile at this ref is one entry stale, and the guard was made exact rather than
dropped.** #922 removed seven dependencies from `package.json` and from `bun.lock`'s
`workspaces` block but left one resolved entry in the `packages` map —
`@midnight-ntwrk/midnight-js-fetch-zk-config-provider@4.1.1`, which nothing depends on any more
— so `bun install --frozen-lockfile` refuses a correct tree with *"lockfile had changes, but
lockfile is frozen"*. (The other six are still reachable transitively through
`@effectstream/midnight-contracts` and `midnight-js-protocol`.) Measured with
`bun install --lockfile-only` on the extracted tree: the ENTIRE drift is the removal of that one
entry — 683 packages, no addition, no version change. The image therefore installs unfrozen and
then requires that the resolution added nothing, changed nothing and removed only that orphan.
That is strictly stronger than the frozen flag, and an empty diff satisfies it too, so it keeps
working the day upstream regenerates the lockfile.

### Re-pin (00011 PR A) to the branch head after #918 — the whole-coin line

`FRONTEND_REF` moved to `58ab921` (from `f20a38c`), subtree `3ca1d56f` (from `99b871f7`), for
[effectstream#918](https://github.com/effectstream/effectstream/pull/918), *"amounts are whole
coins — token decimals from the registry"*. **This is the UI half of kernel PR #63 and moves
together with `KERNEL_REF`**: the kernel now defaults `known_tokens.decimals` to 6 and mints
whole coins, and the SPA now reads each token's `decimals` off `GET /v1/known-tokens`, scales
every amount it displays and every amount it submits by `10^decimals`, sends an explicit
`decimals` when it registers a freshly minted colour, and mints **1 000 whole coins**
(`parseWholeCoins('1000', 6)` = `1_000_000_000` base units) where it used to mint 1 000 base
units. A stack carrying only one half of the pair is wrong by exactly `10^6`.

The two commits between the refs touch only `src/**` (new `src/state/{amount,swapAmounts}.ts`
and their tests, plus the screens/hooks/services that consume them) and `README.md` — **no
`package.json`, no `bun.lock`, no `.compact` source, no build script, no `vite.config.ts`** —
so every assertion above was re-checked against the new subtree BEFORE building and holds
verbatim (`ledger-v8 8.1.0`, no `ledger-v9` in `package.json` or the resolved `bun.lock`,
`compact-runtime 0.16.0`, `@effectstream/{midnight-contracts,wallets} 0.104.0`, no `0.200.x`,
the #912 `pageHost` / `'proofServerUri'` markers, both LICENSE files), and the compactc 0.31.0
toolchain and the committed contract manifest this image verifies byte-for-byte are unaffected.

### Re-pin (phase G) to the branch head after #916

`FRONTEND_REF` moved to `f20a38c` (from `8d21ebe`) for
[effectstream#916](https://github.com/effectstream/effectstream/pull/916), "reference rate,
offset and sponsorship threshold" — the SPA-side counterpart of kernel PR #54/#56 (seeded
reference prices, `GET /v1/prices`, the sponsorship gate), letting the page show the threshold
the kernel now warns/enforces on. The 20 commits between the two refs touch only
`src/screens/{Market,Swap}.tsx` and new `src/state/{reference,format,usePrices}.ts` — no
`package.json`, no `.compact` source, no build script, no `vite.config.ts` — so every assertion
above was re-checked against the new subtree and holds verbatim, and the compactc 0.31.0
toolchain this image pins separately is unaffected.

The kernel's `GET /v1/midnight/config` reports the URIs **the kernel itself dials**. Inside
Docker Compose those are service hostnames (`indexer`, `proof-server`) on a network no browser
can resolve, on container ports the host may publish elsewhere. The page's JS wallet, contract
client and take-offer flow all read that config, so the fix belongs at that single chokepoint.

The patch does two things, in order:

1. **Explicit overrides win.** `<camelCase>Uri` reads `window.<SCREAMING_SNAKE_CASE>`, which
   the entrypoint writes into `/config.js` from the container environment
   (`NODE_URI`, `INDEXER_URI`, `INDEXER_WS_URI`, `PROOF_SERVER_URI`). An override is injected
   even when the backend omits the key, which is why `nodeUri` is in the list: the kernel never
   reports it, and the in-page JS wallet otherwise falls back to `http://<pageHost>:9944`.
2. **Otherwise, rewrite a bare hostname.** A dot-less, non-`localhost` hostname is a compose
   service name; it is re-pointed at the page's own host, keeping scheme, port and path.

### Divergence from the 2.x sibling's patch, and why

Step 2 alone IS the 2.x patch, and it was verified to apply to this unpatched v8 tree cleanly
at zero offset before being extended (`git apply --check` clean; `ledger-v9.patch` never
touched `api.ts`, so this was expected and is now measured). Step 1 is new here.

The reason is a real defect, not a preference: a hostname-only rewrite keeps the CONTAINER
port. `http://indexer:8088/...` becomes `http://127.0.0.1:8088/...`, which is right only when
the stack publishes the indexer on 8088 — i.e. only on the default port block. This repository
ships `scripts/pick-ports.sh`, whose whole purpose is a random free port block, and
`scripts/ci-check.sh` uses it. Without step 1 the SPA on any generated stack dials ports
nothing is listening on, and the failure looks like a dead indexer rather than a
misconfiguration. `pick-ports.sh` therefore emits all four `FRONTEND_*_URI` overrides
alongside `FRONTEND_API_BASE`/`FRONTEND_BATCHER_URL`.

## The contract, and the compiler that used to compile it — BOTH GONE at `400880ce`

> **History.** Everything in this section describes the image up to `FRONTEND_REF=58ab921…`.
> effectstream #922 deleted the template's Compact source, its build script and its committed
> manifest, so this image has no `compact` stage, no `COMPACT_VERSION` build arg and no entry in
> `config/artifact-decisions.json` → `toolchains` any more. It is kept because it explains what
> the image used to prove, and because the byte-identity it records is why the two sides could be
> compiled by different compilers at all.

`src/contract/offer-files.compact` is byte-identical to the kernel's own
`packages/contracts-midnight/contract-offer-files/src/offer-files.compact`
(sha256 `6fde5f8e2cfc5d5559f1468f3997f72810aec3093c6a87a54036b9175dadd3f0` on both sides), and
the template's `src/contract/manifest.json` names the kernel package as its provenance.

The template compiles it with **compactc 0.31.0**, and that is not our choice: its
`scripts/build-contract.ts` pins `COMPILER_VERSION = "0.31.0"` and its committed
`manifest.json` records the sha256 of the source and of all 16 outputs, failing the build on
any mismatch. `compact compile` is deterministic, so that manifest is an exact check. The
image runs it (`--verify-only`) as its fail-closed gate; routine builds must never
self-bless compiler output with `--update-manifest`.

**There were two Compact toolchains for this one contract, on purpose.** The kernel image
compiled the source with 0.30.0 (its package pragma, paired with compact-runtime 0.15.0); this
image compiled with 0.31.0 (paired with compact-runtime 0.16.0, which the generated module
version-checked at import time). **Both ends are now gone** — the kernel's with kernel #69
(00020 PR C), the template's with effectstream #922 (00020 PR D) — and the `compact` entry was
removed from `config/artifact-decisions.json`, leaving two Compact toolchains in the repository
that compile contracts which still exist (shielded-night 0.31.1, issuer 0.31.1).

Both are fetched from `midnightntwrk/compact` (repository id 967499978) — NOT
`LFDT-Minokawa/compact` (id 1115336329), which is a different repository. For
`compactc-v0.31.0` the two publish byte-identical assets (same sha256, same sizes, verified
2026-09-01); `midnightntwrk/compact` is preferred because it is where the `compact` toolchain
manager itself is published, so it is what `compact update <v>` resolves against, and because
the kernel image already pins there — one fewer distinct upstream in the stack.

## Licenses

The upstream `LICENSE-APACHE` and `LICENSE-MIT` notices are copied from the pinned source into
`/usr/share/licenses/zswap-da/` in the runtime image, together with this file.
