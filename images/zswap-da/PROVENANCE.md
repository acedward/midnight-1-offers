# zswap-da frontend build provenance

## Where the source comes from

The image fetches `templates/zswap-da` directly from
[`effectstream/effectstream`](https://github.com/effectstream/effectstream) at the immutable
commit `332503c8f9216143a8c805f2a0acbcfd39e5a21d`, whose template subtree is
`1f63d7eedc9a8aff729b7fe026486cb89cb618de`. BOTH identities are verified before checkout —
the commit alone does not prove which bytes of it were extracted — and the resolved commit is
recorded as `/.zswap-da-commit` inside the runtime image, so "what is in here?" never depends
on remembering which tag it was built as. No third-party SPA source is stored in this
repository, and no generated `managed/` contract output is committed.

Upstream `templates/**` is FROZEN by effectstream 00016 FR-10. Nothing here may push to it.

## What is NOT applied: the ledger adaptation

The 2.x sibling repository (`midnight-2-offers`) carries a 55 KB `ledger-v9.patch` that
migrates this same template from ledger-v8 to ledger-v9. **This repository ships no such
patch and no such stage**: at this ref the template is already v8-native — `@midnight-ntwrk/`
`ledger-v8` 8.1.0, midnight-js 4.1.1, compact-js 2.5.1, compact-runtime 0.16.0 — which is
exactly the line the 1.x kernel runs. That is asserted in the build rather than assumed: the
source stage requires `"@midnight-ntwrk/ledger-v8": "8.1.0"` in `package.json` and requires
that no `ledger-v9` dependency appears anywhere in it. If upstream ever moved the frozen ref,
the build fails there instead of producing a silently mismatched bundle.

## What IS applied: `browser-network-urls.patch`

One patch, one function: `api.getMidnightConfig` in `src/services/api.ts`. It applies
fail-closed (`git apply --check` first, then two guard greps) — a patch that stops applying
must break the build, never quietly no-op.

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

## The contract, and which compiler compiles it

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

**There are two Compact toolchains in this stack, on purpose.** The kernel image compiles the
same source with 0.30.0 (its package pragma, paired with compact-runtime 0.15.0); this image
compiles with 0.31.0 (paired with compact-runtime 0.16.0, which the generated module
version-checks at import time). See `config/artifact-decisions.json` → `toolchains` and Q9.

Both are fetched from `midnightntwrk/compact` (repository id 967499978) — NOT
`LFDT-Minokawa/compact` (id 1115336329), which is a different repository. For
`compactc-v0.31.0` the two publish byte-identical assets (same sha256, same sizes, verified
2026-09-01); `midnightntwrk/compact` is preferred because it is where the `compact` toolchain
manager itself is published, so it is what `compact update <v>` resolves against, and because
the kernel image already pins there — one fewer distinct upstream in the stack.

## Licenses

The upstream `LICENSE-APACHE` and `LICENSE-MIT` notices are copied from the pinned source into
`/usr/share/licenses/zswap-da/` in the runtime image, together with this file.
