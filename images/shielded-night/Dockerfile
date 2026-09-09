# shielded-night — the Shielded NIGHT dApp: a Compact contract that wraps native unshielded
# NIGHT into a contract-minted shielded token (sNight) 1:1 and back, plus the Vite/React page
# that drives it.
#
# ONE BUILD, TWO RUNTIME TARGETS, and they are deliberately different base images:
#
#   --target web      nginx serving the built SPA on container :10900, together with the
#                     compiled contract artifacts the browser's prover fetches. SINCE upstream
#                     #14 that path is /contract/v1/shielded-night/ — the adapter resolves
#                     `<page origin>/contract/<profile>/shielded-night` and `undeployed` is the
#                     `midnight-1.x` family; /contract/v2/ and the pre-#14
#                     /contract/compiled/ are emitted and served too (see nginx.conf). Its
#                     entrypoint writes /config.js with THIS stack's contract address at
#                     container start.
#   --target deploy   the bun runtime carrying the pinned tree and its root node_modules, for
#                     the deploy one-shot (entrypoint-deploy.sh), the verify driver
#                     (entrypoint-verify.sh) and the registry one-shot
#                     (entrypoint-token-name.sh). No SPA, no frontend node_modules. It also
#                     carries `psql` and sql/snight-registry-patch.sql, because the registry
#                     one-shot patches the kernel's seeded SNIGHT row with the colour it
#                     derives here (00015 / organizer issues/00012).
#
# SOURCE IS FETCHED DIRECTLY from effectstream/shielded-night at an immutable full commit. No
# dApp source and no generated `managed/` output is committed to this repository, so a cold
# build needs GitHub + npm network access. See PROVENANCE.md.
#
# NO PATCH OF ANY KIND, of the source OR of the built output. The things a compose-hosted
# deployment needs from this dApp — a
# RUNTIME contract-address override, env-overridable `undeployed` endpoint URLs, and an
# external-stack mode for its integration suite — live UPSTREAM (project 00007 question Q2,
# owner decision A). This build ASSERTS each of them is present in the pinned tree, so a
# re-pin to a tree without them fails HERE rather than producing a page that can never learn
# its address and a one-shot that dials 127.0.0.1 inside a container.
#
# THE CONTRACT IS RECOMPILED HERE and the output must be BYTE-IDENTICAL to the `src/managed/`
# the pinned tree commits (project 00007 question Q3, owner decision A). That byte-exactness
# is the dApp's whole verifiability claim — "the on-chain verifier keys are the ones compiled
# from this source" — and its own CI proves it on every push. This image reproduces the proof
# locally instead of trusting it, with the compiler the tree itself names.

# ── base images: index digests, not tags ─────────────────────────────────────
# DEBIAN_BASE and NGINX_BASE are the SAME two digests images/zswap-da and images/offerfiles-kernel
# pin — fewer distinct external identities in the stack, and ones already vetted. All are good
# official multiarch indexes (linux/amd64 + linux/arm64), so nothing here needs a `platform:`
# pin and both architectures build native.
#
# BUN_BASE is DELIBERATELY NOT the 1.3.11 the kernel and zswap-da images share (phase G, plan
# question Q13). The pinned shielded-night tree's lockfiles were regenerated wholesale on bun
# 1.4.0 (upstream PR effectstream/shielded-night#12/#11's line, Q11 -> A) and bun 1.4 writes
# `"lockfileVersion": 2`, a format 1.3.11 cannot parse at all — `bun install --frozen-lockfile`
# on this stage would fail immediately with "Unknown lockfile version" rather than resolve a
# stale dependency. This is the ONE image in this repository on bun 1.4: the kernel's deploy
# entrypoint and zswap-da's build both stay on 1.3.11, which is load-bearing there (1.3.14+
# breaks the kernel's `midnight-contract:deploy` with a graphql-tag/ESM require() error) and
# unrelated to this tree's lockfile format.
#
# NODE_BASE is NEW in 00020 PR E and exists for exactly one reason: upstream #13's two browser
# protocol trees (frontend/protocols/{v1,v2}) carry package-lock.json and are installed with
# `npm ci`, and `oven/bun:1.4.0` ships a node fallback binary but NO npm (measured). It is the
# SAME digest images/issuer pins for its own build stage — one fewer distinct external identity,
# and one already vetted here. It is a build-only stage: nothing from it reaches either runtime
# target except the two resolved node_modules trees.
ARG DEBIAN_BASE=debian:trixie-slim@sha256:f6e2cfac5cf956ea044b4bd75e6397b4372ad88fe00908045e9a0d21712ae3ba
ARG BUN_BASE=oven/bun:1.4.0@sha256:5ff609364c049b54eb0ff560ec96319729a972078ef2c755d758f0c6ef89c2d6
ARG NODE_BASE=node:24.15.0-trixie@sha256:8202a46483627d14c75c8078d8c1b1d8ec14b792390c7001adb4f698724c4ca9
ARG NGINX_BASE=nginx:1.27-alpine@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10

ARG SHIELDED_NIGHT_REPO=https://github.com/effectstream/shielded-night.git
ARG SHIELDED_NIGHT_REF=2bb32838a0572019a49436c3743bae7d0299817a
# NOT a free choice: the pinned tree's package.json runs `compact compile +0.31.1` and its CI
# pins COMPACT_VERSION 0.31.1. Stage `source` asserts the tree still says so, so this ARG and
# the source can never drift apart silently.
ARG COMPACT_VERSION=0.31.1

# ── stage 0: the exact upstream tree, and what it must contain ───────────────
FROM ${DEBIAN_BASE} AS source

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

ARG SHIELDED_NIGHT_REPO
ARG SHIELDED_NIGHT_REF

WORKDIR /upstream
RUN set -eux; \
    # A full 40-hex commit, always. `git fetch --depth 1 origin <sha>` refuses an abbreviated
    # sha and cannot see a branch move, which is the cheapest possible enforcement of this
    # repository's pinning rule.
    case "${SHIELDED_NIGHT_REF}" in \
      ????????????????????????????????????????) : ;; \
      *) echo "FAIL: SHIELDED_NIGHT_REF must be a full 40-character commit SHA, got '${SHIELDED_NIGHT_REF}'" >&2; exit 1 ;; \
    esac; \
    case "${SHIELDED_NIGHT_REF}" in *[!0-9a-f]*) echo "FAIL: SHIELDED_NIGHT_REF must be lowercase hex" >&2; exit 1 ;; esac; \
    git init -q .; \
    git remote add origin "${SHIELDED_NIGHT_REPO}"; \
    git fetch -q --depth 1 origin "${SHIELDED_NIGHT_REF}"; \
    actual="$(git rev-parse FETCH_HEAD)"; \
    test "${actual}" = "${SHIELDED_NIGHT_REF}"; \
    git checkout -q FETCH_HEAD -- .; \
    mkdir /src; \
    cp -a /upstream/. /src/; \
    rm -rf /src/.git; \
    printf '%s' "${actual}" > /.shielded-night-commit

# THE 1.x / ledger-v8 ASSERTION, in both directions and in both packages.
#
# This repository's core is node 1.0.1 / indexer 4.3.3 / proof-server 8.1.0, i.e. the ledger-v8
# line. The 2.x sibling's copy of this profile pins a ledger-v9 branch of the same repository.
# Nothing but a pin distinguishes them, so the pin is checked rather than trusted: the exact
# v8 override must be present, compact-runtime must be 0.16.0, and NO ledger-v9 PACKAGE may
# appear anywhere IN THIS STACK'S LANE — not as a DEPENDENCY in a package.json and not as a
# resolved entry in a lockfile, which is the half a package.json grep cannot see. A tree with two
# ledger wasm instances fails `instanceof` during proving, hours later and nowhere near the cause.
#
# THE PATTERN IS THE PACKAGE NAME, "@midnightntwrk/ledger-v9" (a JSON key, quoted), NOT the
# bare substring "ledger-v9" — measured 2026-09-03 (project 00007 phase H2) against
# main @ f7fcefa: PR #12's `//overrides` note explains IN PROSE why compact-js is pinned
# ("...depends on an unpublished @midnight-ntwrk/ledger-v9 alpha..."), and a bare-substring grep
# false-positives on that comment, failing every build past that commit even though no such
# package is actually a dependency anywhere in the tree. The narrower pattern still catches the
# real hazard (an actual ledger-v9 dependency or resolved lockfile entry) and does not fire on
# prose that merely mentions the string.
#
# ── WHAT "THIS STACK'S LANE" MEANS SINCE upstream #13, and why this list grew ──
#
# Before #13 the whole tree was one lane and four files said so. #13 split the browser side into
# ISOLATED PROTOCOL TREES — frontend/protocols/v1 (midnight-1.x) and frontend/protocols/v2
# (midnight-2.x) — each with its own package-lock.json, precisely so the two Compact runtimes and
# their two WASM class identities can never meet in one physical node_modules. So ledger-v9 IS in
# the pinned tree now, on purpose, in exactly two places: frontend/protocols/v2 (2 + 4 hits) and
# contracts/v2 (2 + 12), both measured at 2bb32838a.
#
# THE OLD FOUR-FILE CHECK WAS THEREFORE STILL TRUE AND NO LONGER SUFFICIENT: it never looked at
# frontend/protocols/v1, which is the tree that now actually builds the adapter this stack's page
# runs (frontend/src/lib/networks.ts gives `undeployed` protocolFamily `midnight-1.x`, asserted
# below). Six files are checked now — the four that were, plus protocols/v1's package.json and
# package-lock.json — and protocols/v1 is checked in the POSITIVE direction too, because "no v9"
# and "the v8 this stack runs" are different claims and a tree with neither would pass the first.
#
# frontend/protocols/v2 and contracts/v2 are deliberately NOT in the list. They are the 2.x lane;
# nothing on `undeployed` can select them, and their whole point is being a separate resolution
# root. Asserting v9's ABSENCE there would fail a correct tree; asserting its PRESENCE would pin
# an upstream implementation detail this stack does not depend on.
RUN set -eux; \
    cd /src; \
    grep -q '"@midnight-ntwrk/ledger-v8": "8.1.0"' package.json; \
    grep -q '"@midnight-ntwrk/ledger-v8": "8.1.0"' frontend/package.json; \
    grep -q '"@midnight-ntwrk/compact-runtime": "0.16.0"' package.json; \
    grep -q '"@midnight-ntwrk/compact-runtime": "0.16.0"' frontend/package.json; \
    # THE v1 BROWSER PROTOCOL TREE, in both directions (upstream #13). Its package-lock.json is
    # what `npm ci` in stage `protocols` resolves, and what vite.config.ts's
    # profileRuntimeResolution() plugin routes every src/managed import to.
    for f in frontend/protocols/v1/package.json frontend/protocols/v1/package-lock.json; do \
      test -f "$f" || { echo "FAIL: ${f} is missing — upstream #13's isolated v1 protocol tree is not in this pin" >&2; exit 1; }; \
      grep -q '"@midnight-ntwrk/ledger-v8": "8.1.0"' "$f" \
        || { echo "FAIL: ${f} does not pin @midnight-ntwrk/ledger-v8 8.1.0; the v1 adapter this stack runs would be off the v8 line" >&2; exit 1; }; \
      grep -q '"@midnight-ntwrk/compact-runtime": "0.16.0"' "$f" \
        || { echo "FAIL: ${f} does not pin @midnight-ntwrk/compact-runtime 0.16.0" >&2; exit 1; }; \
    done; \
    for f in package.json frontend/package.json bun.lock frontend/bun.lock \
             frontend/protocols/v1/package.json frontend/protocols/v1/package-lock.json; do \
      if grep -q '"@midnightntwrk/ledger-v9"' "$f"; then \
        echo "FAIL: ${f} depends on @midnightntwrk/ledger-v9; this repository targets the 1.x/v8 line" >&2; \
        echo "      (ledger-v9 is expected ONLY in frontend/protocols/v2 and contracts/v2, the isolated 2.x lane)" >&2; \
        exit 1; \
      fi; \
    done

# THE COMPILER THE TREE ITSELF NAMES must be the one this image fetches. `compact compile
# +<version>` in package.json is the dApp's own statement of which toolchain produced the
# committed src/managed/, and stage `compact` below asserts byte-equality against it — so a
# COMPACT_VERSION that disagreed with this line would fail later as an inscrutable diff of
# binary keys rather than as the version mismatch it is.
ARG COMPACT_VERSION
RUN set -eux; \
    cd /src; \
    grep -q "compact compile +${COMPACT_VERSION} " package.json \
      || { echo "FAIL: package.json does not compile with +${COMPACT_VERSION}" >&2; \
           grep -n 'compact compile' package.json >&2; exit 1; }

# ── the three integration knobs this profile is built on ─────────────────────
#
# Each is asserted at its source of truth, by the name the demo stack actually uses, so the
# failure names the missing knob instead of appearing as a page with an empty dropdown or a
# one-shot that times out against 127.0.0.1.
RUN set -eux; \
    cd /src; \
    # 1. RUNTIME contract address: window.SHIELDED_NIGHT.<NETWORK>_ADDRESS wins over the
    #    build-time env var. Without it a stack-independent image is impossible — the address
    #    only exists after this stack's own deploy.
    test -f frontend/src/lib/runtime-config.ts \
      || { echo "FAIL: the pinned tree has no frontend/src/lib/runtime-config.ts — the runtime address override is missing" >&2; exit 1; }; \
    grep -q 'UNDEPLOYED_ADDRESS' frontend/src/lib/runtime-config.ts; \
    grep -q 'runtime-config' frontend/src/lib/networks.ts \
      || { echo "FAIL: networks.ts does not consult the runtime config; the override lane is dead" >&2; exit 1; }; \
    # 1b. …AND the file that carries it must be part of the BUILD, not something a deployment
    #     bolts on afterwards. Upstream ships frontend/public/config.js (a no-op that only
    #     ensures the global exists) and references it from index.html as a CLASSIC script, so
    #     it runs before the deferred module bundle. That is what lets this image patch nothing
    #     at all: it overwrites one already-served file at container start.
    test -f frontend/public/config.js \
      || { echo "FAIL: the pinned tree ships no frontend/public/config.js placeholder" >&2; exit 1; }; \
    grep -q '<script src="/config.js">' frontend/index.html \
      || { echo "FAIL: index.html does not load /config.js" >&2; exit 1; }; \
    # 2. Endpoint overrides: a deploy running INSIDE compose must dial service hostnames.
    for v in MN_INDEXER_URL MN_INDEXER_WS_URL MN_NODE_URL MN_PROOF_SERVER_URL; do \
      grep -q "$v" test/support/network.ts \
        || { echo "FAIL: test/support/network.ts does not honour ${v}" >&2; exit 1; }; \
    done; \
    # 3. External-stack mode: the round-trip gate is the UPSTREAM suite run against OUR stack,
    #    not a transcribed copy of it and not a throwaway testcontainers devnet.
    grep -q 'MN_EXTERNAL_STACK' test/integration/global-setup.ts \
      || { echo "FAIL: the integration suite has no external-stack mode (MN_EXTERNAL_STACK)" >&2; exit 1; }; \
    # …and the machine-readable deploy record, so the one-shot never scrapes stdout.
    grep -q 'DEPLOY_OUT' scripts/deploy-record.ts \
      || { echo "FAIL: scripts/deploy-record.ts does not implement DEPLOY_OUT" >&2; exit 1; }

# ── knob 4: THE PROTOCOL THIS STACK'S PAGE SELECTS (upstream #13) ─────────────
#
# Until #13 there was one protocol and no choice to make. Now every network in
# frontend/src/lib/networks.ts carries a `protocolFamily`, and
# frontend/src/hooks/useShieldedNight.ts branches on exactly that field:
#
#     network.protocolFamily === 'midnight-1.x'
#       ? await import('../../protocols/v1/src/adapter').then(m => m.createV1Adapter(...))
#       : await import('../../protocols/v2/src/adapter').then(m => m.createV2Adapter(...))
#
# `undeployed` is `midnight-1.x` UPSTREAM, so this stack runs the ledger-v8 adapter by upstream's
# own table rather than by an arrangement of ours — and that is exactly why it is asserted here
# instead of assumed. A re-pin that moved `undeployed` to `midnight-2.x` would produce a page that
# loads, offers "Local (undeployed)", and then dials a ledger-v9 adapter at an 8.1.0 chain: a
# failure with no plausible cause anywhere near the pin. The whole entry is matched on one line
# (upstream writes it as a single-line object literal) so the family cannot be read off some
# OTHER network's row.
#
# The three shared modules are asserted by path because the v1 adapter imports all three and a
# vanished one would surface as a module-not-found inside `vite build`, minutes later.
RUN set -eux; \
    cd /src; \
    grep -q "key: 'undeployed'.*protocolFamily: 'midnight-1.x'" frontend/src/lib/networks.ts \
      || { echo "FAIL: networks.ts does not put 'undeployed' on the midnight-1.x protocol family — this stack is the ledger-v8 line and its page would select the v2 adapter" >&2; \
           grep -n "protocolFamily" frontend/src/lib/networks.ts >&2; exit 1; }; \
    grep -q "protocols/v1/src/adapter" frontend/src/hooks/useShieldedNight.ts \
      || { echo "FAIL: useShieldedNight.ts does not import the v1 adapter" >&2; exit 1; }; \
    for f in frontend/protocols/shared/adapter-core.ts frontend/protocols/shared/asset-url.ts \
             frontend/protocols/shared/types.ts frontend/protocols/v1/src/adapter.ts; do \
      test -f "$f" || { echo "FAIL: ${f} is missing — upstream #13's protocol layout is not in this pin" >&2; exit 1; }; \
    done

# ── knob 5: WHERE THE PAGE FETCHES ITS PROVING ASSETS FROM (upstream #14) ─────
#
# #13's adapters passed a RELATIVE './contract/v1/shielded-night' straight to
# FetchZkConfigProvider, whose SDK validates its base with a bare `new URL(baseURL)` and no base
# argument — so pressing Connect wallet threw "Failed to construct 'URL': Invalid URL" before any
# network work started. #14 added frontend/protocols/shared/asset-url.ts, which resolves the tree
# from the page ORIGIN plus the vite base, and the v1 adapter now calls it.
#
# THIS IS LOAD-BEARING FOR THIS IMAGE, not just for the browser: the resolved path is
# `<origin>/contract/v1/shielded-night`, so nginx.conf's `try_files … =404` artifact lane, the
# dist assertions in stage `build`, compose's web healthcheck and scripts/verify-shielded-night.sh
# all name `contract/v1` now. If a re-pin moved the profile segment again, THE PAGE WOULD STILL
# WORK (vite copies the tree and the SPA fallback serves an existing file happily) while a MISS
# would answer 200 with the app shell — the prover handed an HTML document as a proving key, which
# is the exact failure the =404 lane exists to prevent. So the segment is asserted at its source.
RUN set -eux; \
    cd /src; \
    grep -q 'contractAssetBaseUrl' frontend/protocols/shared/asset-url.ts \
      || { echo "FAIL: asset-url.ts does not export contractAssetBaseUrl (upstream #14)" >&2; exit 1; }; \
    grep -q "contractAssetBaseUrl('v1'" frontend/protocols/v1/src/adapter.ts \
      || { echo "FAIL: the v1 adapter does not resolve its proving-asset base through contractAssetBaseUrl (upstream #14)" >&2; \
           grep -n 'FetchZkConfigProvider\|ASSET_PATH' frontend/protocols/v1/src/adapter.ts >&2; exit 1; }; \
    grep -q "contract/\${profile}/\${CONTRACT_ASSET_NAME}" frontend/protocols/shared/asset-url.ts \
      || { echo "FAIL: asset-url.ts no longer builds 'contract/<profile>/shielded-night' — the served path this image, its nginx.conf and verify-shielded-night.sh use has MOVED" >&2; \
           grep -n 'contract/' frontend/protocols/shared/asset-url.ts >&2; exit 1; }; \
    grep -q "dest: 'contract/v1'" frontend/vite.config.ts \
      || { echo "FAIL: vite.config.ts does not copy the v1 managed tree to dist/contract/v1" >&2; \
           grep -n 'viteStaticCopy\|dest:' frontend/vite.config.ts >&2; exit 1; }

# ── stage 0b: the two BROWSER PROTOCOL trees, installed with npm (upstream #13) ──
#
# WHY A SEPARATE STAGE AT ALL. frontend/protocols/{v1,v2} carry package-lock.json, not a bun
# lockfile, and upstream's own frontend CI job installs them with `npm ci` — one per tree,
# deliberately, because vite.config.ts's profileRuntimeResolution() plugin resolves every
# `@midnight-ntwrk/compact-runtime` import made from src/managed/ or contracts/v2/managed/ to
# `frontend/protocols/<profile>/node_modules/...`. Two physically separate resolution roots is the
# mechanism, not an accident: one holds compact-runtime 0.16.0 + ledger-v8 8.1.0, the other 0.19.0
# + ledger-v9, and a single node_modules would give the WASM classes one identity and break
# `instanceof` during proving.
#
# MEASURED, which is why this stage exists rather than two more lines in `build`:
# `oven/bun:1.4.0` ships a `node` fallback binary at /usr/local/bun-node-fallback-bin/node and
# NO npm at all (`command -v npm` finds nothing). `bun install` is not a substitute — it would
# re-resolve from package.json and migrate the npm lockfile, throwing away the exact pinned set
# that IS the isolation.
#
# The node base is the digest images/issuer already pins for its own build stage — one fewer
# distinct external identity in this repository, and one already vetted. Nothing from this stage
# reaches a runtime target: only the two node_modules trees are copied into `build`.
FROM ${NODE_BASE} AS protocols

WORKDIR /protocols
# Only the manifests, so a change anywhere else in the pinned tree does not re-run two installs.
COPY --from=source /src/frontend/protocols/v1/package.json      /protocols/v1/package.json
COPY --from=source /src/frontend/protocols/v1/package-lock.json /protocols/v1/package-lock.json
COPY --from=source /src/frontend/protocols/v2/package.json      /protocols/v2/package.json
COPY --from=source /src/frontend/protocols/v2/package-lock.json /protocols/v2/package-lock.json

# `npm ci`, not `npm install`: it installs exactly the lockfile and fails when the lockfile and
# the manifest disagree — the same guarantee `bun install --frozen-lockfile` gives the other two
# trees, and the same command upstream's CI runs.
RUN set -eux; \
    npm --version; \
    cd /protocols/v1 && npm ci --no-audit --fund=false; \
    cd /protocols/v2 && npm ci --no-audit --fund=false; \
    # The one file the whole arrangement rests on, per profile, at the exact path
    # profileRuntimeResolution() hands to rollup. A silently empty install would otherwise
    # surface as an unresolved import minutes into `vite build`.
    for p in v1 v2; do \
      test -f "/protocols/${p}/node_modules/@midnight-ntwrk/compact-runtime/dist/index.js" \
        || { echo "FAIL: /protocols/${p} has no @midnight-ntwrk/compact-runtime/dist/index.js — vite.config.ts's profileRuntimeResolution() would resolve to a path that does not exist" >&2; exit 1; }; \
    done; \
    # …and the two runtimes must be DIFFERENT builds, which is the entire point of installing
    # both. Identical bytes here would mean the isolation collapsed and both generated contracts
    # were sharing one WASM identity again.
    if cmp -s /protocols/v1/node_modules/@midnight-ntwrk/compact-runtime/package.json \
              /protocols/v2/node_modules/@midnight-ntwrk/compact-runtime/package.json; then \
      echo "FAIL: the v1 and v2 protocol trees resolved the SAME compact-runtime; upstream #13's WASM-identity isolation is gone" >&2; exit 1; \
    fi; \
    echo "OK: v1 compact-runtime $(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' /protocols/v1/node_modules/@midnight-ntwrk/compact-runtime/package.json | head -1), v2 $(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' /protocols/v2/node_modules/@midnight-ntwrk/compact-runtime/package.json | head -1)"

# ── stage 1: recompile the contract, and prove it is the committed one ───────
# Fetched as a release asset and SHA-256 verified, rather than run through the `compact`
# version manager whose resolution is an unpinnable network lookup. `compactc <in> <out>` is
# exactly what `compact compile +V <in> <out>` dispatches to.
FROM ${DEBIAN_BASE} AS compact

ARG COMPACT_VERSION
ARG TARGETARCH
ARG COMPACT_REPO=midnightntwrk/compact
# SHA-256 of each release asset, from the GitHub release API's own `digest` field
# (2026-09-02). These, not the URL, are the compiler's identity: a release asset can be
# re-uploaded under the same name. midnightntwrk/compact and LFDT-Minokawa/compact publish
# byte-identical assets for this tag (verified — same sha256, same sizes); the former is used
# because it is where the toolchain manager itself is published and where this repository's
# other two Compact pins already point.
ARG COMPACT_SHA256_AMD64=e291b4bab4d4e857707008f8b1c25c2b8e0c843f6c737d0ee6c0d9ac69a6bbfb
ARG COMPACT_SHA256_ARM64=7c7e38581808779d2671687c3378017bcf2fb3111a192fd1253f3472012df549

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates unzip \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) triple="x86_64-unknown-linux-musl";  want_sha="${COMPACT_SHA256_AMD64}" ;; \
      arm64) triple="aarch64-unknown-linux-musl"; want_sha="${COMPACT_SHA256_ARM64}" ;; \
      *) echo "FAIL: unsupported TARGETARCH='${TARGETARCH}' (need amd64 or arm64)" >&2; exit 1 ;; \
    esac; \
    asset="compactc_v${COMPACT_VERSION}_${triple}.zip"; \
    # The same release ships aarch64-darwin and x86_64-darwin zips. A darwin asset in a Linux
    # build stage is exactly what the matrix's forbiddenAssetSubstrings list exists to
    # prevent; assert it cannot happen here either.
    case "${asset}" in \
      *darwin*|*macos*|*windows*) echo "FAIL: '${asset}' is not a Linux asset" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/${COMPACT_REPO}/releases/download/compactc-v${COMPACT_VERSION}/${asset}"; \
    echo "fetching ${url}"; \
    curl --proto '=https' --tlsv1.2 -fLsS --retry 3 --retry-delay 2 -o /tmp/compactc.zip "${url}"; \
    echo "${want_sha}  /tmp/compactc.zip" | sha256sum -c -; \
    mkdir -p /opt/compactc; \
    unzip -q /tmp/compactc.zip -d /opt/compactc; \
    rm -f /tmp/compactc.zip; \
    chmod +x /opt/compactc/*; \
    # The zkir backend ships beside compactc and is invoked as a sibling from `dirname $0`.
    # An asset without it compiles nothing and fails much later, as a missing executable.
    test -x /opt/compactc/zkir || { echo "FAIL: the asset lacks the default zkir backend" >&2; exit 1; }; \
    # The pin says 0.31.1; make the BINARY say so too. A renamed or re-uploaded asset would
    # otherwise be caught by nothing until a verifier key was rejected at runtime.
    ver="$(/opt/compactc/compactc --version 2>&1 || true)"; \
    echo "compactc reports: ${ver}"; \
    case "${ver}" in \
      *"${COMPACT_VERSION}"*) : ;; \
      *) echo "FAIL: compactc does not report version ${COMPACT_VERSION}: ${ver}" >&2; exit 1 ;; \
    esac

# The contract source AND the committed artifacts: one is compiled, the other is what the
# result must equal. Both come from the pinned tree; nothing else in it invalidates this layer.
#
# THE SOURCE PATH IS PART OF THE OUTPUT, which is not obvious and cost a build to discover.
# compactc records the input path it was given, verbatim, in the emitted source map
# (`contract/index.js.map`: `sourceRoot` and `sources`). Compiling the same bytes as
# `/contract/shielded-night.compact` instead of `src/shielded-night.compact` therefore produces
# artifacts that are byte-identical in every ZK key, every zkir and the contract module itself —
# and differ in exactly two lines of the map. So the layout and the invocation mirror upstream's
# `compact compile +0.31.1 src/shielded-night.compact src/managed/`, run from the repository
# root, and the byte-exactness assertion below stays exact instead of being loosened to
# "everything except the source map".
COPY --from=source /src/src/shielded-night.compact /src/src/shielded-night.compact
COPY --from=source /src/src/managed /committed/managed
WORKDIR /src

# THE BYTE-EXACT REBUILD. Compiled into an EMPTY directory, exactly as upstream's own
# reproducible-build job does (it `rm -rf src/managed` first): a compiler that skipped work
# because its output was already present would leave the committed files untouched and the
# diff below would pass while having verified nothing.
#
# HOME and XDG_CACHE_HOME are redirected because the default HOME is /root, and an SRS cache
# written there would be baked into a layer nothing reads.
RUN set -eux; \
    HOME=/tmp XDG_CACHE_HOME=/tmp/zk-cache \
      /opt/compactc/compactc src/shielded-night.compact src/managed/; \
    test -d /src/src/managed/contract; \
    test -d /src/src/managed/keys; \
    test -d /src/src/managed/zkir; \
    # 11 circuits, each with a prover key, a verifier key and a bzkir. The count is asserted
    # because "the compile produced SOMETHING" and "the compile produced this contract" are
    # different claims, and only the second one is worth anything.
    n="$(ls -1 /src/src/managed/keys/*.verifier | wc -l)"; \
    test "${n}" -eq 11 || { echo "FAIL: expected 11 circuits, compiled ${n}" >&2; ls -1 /src/src/managed/keys >&2; exit 1; }; \
    # THE ASSERTION THIS WHOLE STAGE EXISTS FOR. `compact compile` is deterministic, so this
    # is exact, not heuristic: a difference means the source was edited, the compiler version
    # differs, or the committed artifacts are not what this source produces — and in every one
    # of those cases the page would serve proving keys that do not match the deployed
    # contract's on-chain verifier keys.
    if ! diff -r /src/src/managed /committed/managed; then \
      echo "FAIL: recompiling src/shielded-night.compact with compactc ${COMPACT_VERSION} did not reproduce the committed src/managed/." >&2; \
      echo "      That byte-exactness IS this dApp's verifiability claim; do not weaken this check." >&2; \
      exit 1; \
    fi; \
    echo "OK: 11 circuits reproduced byte-for-byte from the pinned tree"

# ── stage 2: install ALL FOUR dependency sets, typecheck, build the SPA ──────
FROM ${BUN_BASE} AS build

WORKDIR /src
COPY --from=source /src /src
# The freshly compiled artifacts, not the committed copy — byte-identical by the assertion
# above, but this makes "what the page serves" and "what this build compiled" the same bytes
# by construction rather than by argument.
COPY --from=compact /src/src/managed /src/src/managed
# The two npm-resolved browser protocol trees (upstream #13, stage `protocols`). They are
# node_modules ONLY — the source of both adapters came down with the pinned tree above, and the
# manifests are already there; what stage `protocols` adds is the two isolated resolution roots
# that vite.config.ts's profileRuntimeResolution() plugin hands to rollup by absolute path.
COPY --from=protocols /protocols/v1/node_modules /src/frontend/protocols/v1/node_modules
COPY --from=protocols /protocols/v2/node_modules /src/frontend/protocols/v2/node_modules

# ALL FOUR INSTALLS MATTER, and installing only the frontend's would make this build pass
# trivially while testing nothing. The frontend imports the compiled contract from
# ../src/managed — OUTSIDE its package root — so Rollup resolves the WASM-bearing midnight
# packages for those files from the ROOT node_modules: a second physical copy whose classes
# fail the app's `instanceof` checks. `vite.config.ts`'s `resolve.dedupe` is the fix, and it
# is only EXERCISED when both installs are present. This is upstream's own CI reasoning.
#
# SINCE upstream #13 there are FOUR, and upstream's CI comment says why in one sentence: "Every
# install matters. The v1/v2 package trees intentionally carry separate WASM class identities;
# vite.config.ts routes each generated contract import through its matching profile runtime."
# The other two are the `npm ci` runs in stage `protocols` (bun cannot do them — `oven/bun:1.4.0`
# has no npm, and `bun install` would re-resolve rather than install the pinned lockfile).
# BOTH adapters are bundled even though only one runs: useShieldedNight.ts reaches them through
# `await import('../../protocols/v{1,2}/src/adapter')` with a STATIC string, which rollup resolves
# at build time into two chunks. `frontend/tsconfig.json` also includes `protocols/*/src`,
# `protocols/shared` and ../contracts/v2/managed/contract/index.d.ts, so the frontend TYPECHECK
# needs them too. Upstream does NOT install contracts/v2 for the frontend job, and neither does
# this image: the v2 contract's own `index.d.ts` type-resolves against the root tree.
#
# Frozen: the lockfiles at the pinned commit ARE the tested dependency set, so a transitive
# dependency publishing a new version is a build failure rather than a silent difference.
RUN bun install --frozen-lockfile
RUN cd frontend && bun install --frozen-lockfile

RUN bun run typecheck
RUN cd frontend && bun run typecheck
RUN cd frontend && bun run build

# THE OVERRIDE LANE MUST SURVIVE INTO THE BUNDLE, not merely into the source tree. A
# build-stage grep of the source proves the code was written; only this proves it was shipped.
# `SHIELDED_NIGHT` is a property name on `window`, so minification cannot rename it and
# esbuild emits it verbatim — upstream documents it as exactly this grep marker. Without the
# lane in the bundle, /config.js would be written, served, ignored, and the page would show no
# "Local (undeployed)" network at all.
#
# THE SAME ARGUMENT NOW APPLIES TO THE PROTOCOL CHOICE (upstream #13). `'midnight-1.x'` and
# `'Local (undeployed)'` are string LITERALS, not identifiers, so minification preserves them
# verbatim; finding both in the emitted bundle is what proves the multinetwork table this stack
# depends on was shipped, rather than merely written in the tree stage 0 grepped.
RUN set -eux; \
    grep -rqF 'SHIELDED_NIGHT' /src/frontend/dist/assets \
      || { echo "FAIL: the runtime address-override lane is not in the built bundle" >&2; exit 1; }; \
    grep -rqF 'midnight-1.x' /src/frontend/dist/assets \
      || { echo "FAIL: the built bundle carries no 'midnight-1.x' protocol family — the v1 adapter this stack needs was not shipped" >&2; exit 1; }; \
    grep -rqF 'Local (undeployed)' /src/frontend/dist/assets \
      || { echo "FAIL: the built bundle carries no 'Local (undeployed)' network label — this stack's own network is not selectable" >&2; exit 1; }
# THE THREE SERVED ARTIFACT TREES, and which one the page actually fetches.
#
# `frontend/vite.config.ts`'s viteStaticCopy emits three: `contract/v1/shielded-night` and
# `contract/v2/shielded-night` from the two managed dirs, plus `contract/compiled/shielded-night`
# — the pre-#14 path, kept upstream "for already-open v1 clients during rollout". SINCE #14 THE
# PAGE FETCHES contract/v1 (asset-url.ts resolves `<origin>/contract/<profile>/shielded-night`),
# so that is the one nginx.conf's `=404` lane, compose's healthcheck and
# scripts/verify-shielded-night.sh name — and all three are asserted here because a copy plugin
# that stopped running would leave a page that loads and then cannot prove anything.
#
# v2 IS ASSERTED BUT NOT COMPILED HERE (Q11). `undeployed` is `midnight-1.x`, so nothing on this
# stack can select the v2 adapter or fetch these keys; they come straight from the pinned tree,
# whose byte-exactness at compactc 0.34.0 is upstream's own CI job. Asserting the tree was
# EMITTED still catches the real local failure — a copy target silently dropped by a re-pin.
RUN set -eux; \
    for profile in v1 v2 compiled; do \
      d="/src/frontend/dist/contract/${profile}/shielded-night"; \
      test -d "${d}/keys" || { echo "FAIL: dist has no ${d}/keys — vite's copy target for '${profile}' did not run" >&2; exit 1; }; \
      test -d "${d}/zkir" || { echo "FAIL: dist has no ${d}/zkir" >&2; exit 1; }; \
      n="$(ls -1 "${d}"/keys/*.verifier | wc -l)"; \
      test "${n}" -eq 11 || { echo "FAIL: dist serves ${n} verifier keys under contract/${profile}, expected 11" >&2; ls -1 "${d}/keys" >&2; exit 1; }; \
    done; \
    # THE ONE THE PAGE FETCHES must be the v1 contract THIS STAGE COMPILED, byte for byte — not
    # the v2 tree copied into the wrong destination, which would pass every count above.
    cmp /src/src/managed/keys/convertToShielded.verifier \
        /src/frontend/dist/contract/v1/shielded-night/keys/convertToShielded.verifier \
      || { echo "FAIL: dist/contract/v1 does not carry the v1 verifier keys this build compiled" >&2; exit 1; }; \
    cmp /src/src/managed/contract/index.js \
        /src/frontend/dist/contract/v1/shielded-night/contract/index.js \
      || { echo "FAIL: dist/contract/v1 does not carry the v1 contract module this build compiled" >&2; exit 1; }; \
    # AND THE TWO TREES MUST BE DIFFERENT TREES, discriminated on the contract MODULE rather than
    # on a key. MEASURED at 2bb32838a, and it is not what one would guess: EVERY ONE of the 11
    # verifier keys, the provers and the bzkir are BYTE-IDENTICAL between src/managed (compactc
    # 0.31.1) and contracts/v2/managed (0.34.0) — the two contracts compile to the same constraint
    # system, and ZK keys depend on that and the SRS, not on the emitted bindings. A key
    # comparison here therefore FAILS A CORRECT TREE, which is the one thing an assertion must
    # never do. `contract/index.js` genuinely differs (124 373 vs 128 904 bytes), as do
    # `contract/index.d.ts` and `compiler/contract-info.json`, and v2 additionally ships a
    # `compiler/contract-manifest.json` that 0.31.1 does not emit at all.
    if cmp -s /src/frontend/dist/contract/v1/shielded-night/contract/index.js \
              /src/frontend/dist/contract/v2/shielded-night/contract/index.js; then \
      echo "FAIL: dist/contract/v1 and dist/contract/v2 carry the SAME contract module; one vite copy target is pointing at the wrong managed tree" >&2; exit 1; \
    fi; \
    test -f /src/frontend/dist/contract/v2/shielded-night/compiler/contract-manifest.json \
      || { echo "FAIL: dist/contract/v2 has no compiler/contract-manifest.json — that file is emitted by compactc 0.34.0 and is what identifies this as the 2.x managed tree" >&2; exit 1; }; \
    echo "OK: contract/v1 (this build's own 11 circuits and its contract module), contract/v2 (the 2.x tree, served but unreachable on undeployed) and the legacy contract/compiled are all in dist"

# ── runtime target 1: the deploy one-shot and the verify driver ──────────────
# The bun runtime with the pinned tree and its ROOT node_modules only. No frontend, no
# frontend node_modules: this target never serves a page.
FROM ${BUN_BASE} AS deploy

# ── psql, and the ONE thing in this image that needs it ──────────────────────
# `entrypoint-token-name.sh` patches the kernel's seeded SNIGHT row with THIS stack's colour
# (sql/snight-registry-patch.sql — the statement the kernel's own 000-init.sql prescribes;
# organizer issues/00012). The colour is derived HERE, by driver/snight-driver.ts against the
# contract this stack deployed, so the process that knows the colour is the one that applies
# it: one one-shot, one image, no file contract with a second container (00015 question Q1 ->
# A). The base is Debian trixie, so this is one apt package (~10 MB installed) and the client
# is 17.x — the same major as the stack's `postgres:17-alpine` server.
#
# ASSERTED, not assumed: a base-image change that dropped the package would otherwise surface
# as a one-shot failing at bring-up with "psql: not found".
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends postgresql-client; \
    rm -rf /var/lib/apt/lists/*; \
    command -v psql; \
    psql --version

WORKDIR /app
COPY --from=build /src/package.json /src/bun.lock /src/tsconfig.json \
                  /src/vitest.unit.config.ts /src/vitest.integration.config.ts /app/
COPY --from=build /src/node_modules /app/node_modules
COPY --from=build /src/src     /app/src
COPY --from=build /src/scripts /app/scripts
COPY --from=build /src/test    /app/test
COPY --from=build /src/envs    /app/envs
COPY --from=source /.shielded-night-commit /.shielded-night-commit

# THE FIRST-PARTY DRIVER, and it is deliberately INSIDE /app rather than mounted next to it.
# bun resolves npm dependencies by walking up from the importing FILE, so a driver at /mnt/…
# would look in /mnt/node_modules and /node_modules and find nothing; at /app/driver it finds
# /app/node_modules, and its relative imports of the pinned tree's own test/support primitives
# resolve too. Nothing here is a transcription of that tree — see driver/snight-driver.ts.
COPY driver /app/driver
COPY entrypoint-common.sh /usr/local/lib/shielded-night/entrypoint-common.sh
# VERSIONED SQL, shipped in the image beside the entrypoint that runs it — not inlined into a
# shell string and not mounted from the host. `psql -f` is then given a path an operator can
# `cat`, diff against the kernel's own comment, and run by hand against a live stack.
COPY sql /usr/local/lib/shielded-night/sql
COPY entrypoint-deploy.sh entrypoint-verify.sh entrypoint-token-name.sh /usr/local/bin/
RUN set -eux; \
    chmod 0755 /usr/local/bin/entrypoint-deploy.sh /usr/local/bin/entrypoint-verify.sh \
               /usr/local/bin/entrypoint-token-name.sh; \
    chmod 0644 /usr/local/lib/shielded-night/entrypoint-common.sh; \
    chmod 0644 /usr/local/lib/shielded-night/sql/snight-registry-patch.sql; \
    test -s /usr/local/lib/shielded-night/sql/snight-registry-patch.sql; \
    # The driver imports the pinned tree's test/support primitives by relative path. If a
    # re-pin ever moved or removed one, the failure would be a module-not-found deep inside a
    # `docker compose run` during ./verify.sh; assert it at BUILD time instead.
    test -f /app/test/support/wallet-transfer.ts; \
    test -f /app/test/support/setup-contract.ts; \
    test -f /app/test/support/shielded-night.ts; \
    test -f /app/driver/snight-driver.ts; \
    # The one-shot publishes here; compose mounts a named volume over it. Creating it in the
    # image means a `docker run` without the volume fails on the deploy rather than on a
    # missing directory three steps later.
    mkdir -p /srv/shielded-night

# No CMD: compose names the entrypoint per service, exactly as images/offerfiles-kernel does
# for its three roles.
ENTRYPOINT ["/usr/local/bin/entrypoint-deploy.sh"]

# ── runtime target 2: nginx serving the SPA and the ZK artifacts ─────────────
FROM ${NGINX_BASE} AS web

COPY --from=build  /src/frontend/dist /usr/share/nginx/html
COPY --from=source /.shielded-night-commit /.shielded-night-commit
COPY PROVENANCE.md /usr/share/licenses/shielded-night/PROVENANCE.md

# /config.js is OVERWRITTEN at container start (entrypoint-web.sh) with this stack's contract
# address. NOTHING IS PATCHED HERE: the pinned tree ships the placeholder and the tag, so the
# built output is used exactly as `vite build` emitted it. What is asserted is that both
# survived the build, and IN THE RIGHT ORDER — the tag is a classic script and the bundle a
# deferred module, so a config.js referenced after the module tag would still execute first,
# but a config.js that is not referenced at all is an override lane that silently does nothing.
RUN set -eux; \
    test -f /usr/share/nginx/html/config.js \
      || { echo "FAIL: dist/ carries no config.js — the entrypoint would create a file nothing loads" >&2; exit 1; }; \
    grep -q '<script src="/config.js">' /usr/share/nginx/html/index.html \
      || { echo "FAIL: the built index.html does not load /config.js" >&2; exit 1; }

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY entrypoint-web.sh /docker-entrypoint-shielded-night.sh
RUN set -eux; \
    chmod 0755 /docker-entrypoint-shielded-night.sh; \
    rm -f /etc/nginx/conf.d/default.conf.default; \
    # wasm must be served as application/wasm or streaming instantiation refuses the module.
    # The stock mime.types has carried it since nginx 1.21.5, so this asserts rather than
    # patches: a second `types` block in the same context is a config error, and silently
    # serving wasm as octet-stream is a page that loads and then cannot prove anything.
    grep -qE '^[[:space:]]*application/wasm[[:space:]]+wasm;' /etc/nginx/mime.types \
      || { echo "FAIL: this nginx image's mime.types has no application/wasm mapping" >&2; exit 1; }; \
    # The prover/verifier/bzkir artifacts have no mime mapping at all, which is CORRECT — they
    # must fall through to the http block's `default_type application/octet-stream`. If a base
    # image ever dropped that directive the default would become text/plain, and the SPA's own
    # fetch guard treats a text body as a miss.
    grep -qE '^[[:space:]]*default_type[[:space:]]+application/octet-stream;' /etc/nginx/nginx.conf \
      || { echo "FAIL: this nginx image has no application/octet-stream default_type" >&2; exit 1; }; \
    nginx -t

EXPOSE 10900
ENTRYPOINT ["/docker-entrypoint-shielded-night.sh"]
