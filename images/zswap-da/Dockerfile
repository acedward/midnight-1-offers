# zswap-da — the offer-files trading SPA (React/Vite), served by nginx on container :10600,
# talking to the offer-files kernel API (:9999) and the batcher (:3334).
#
# SOURCE IS FETCHED DIRECTLY from effectstream/effectstream at an immutable full commit and
# the `templates/zswap-da` subtree SHA is verified before checkout. No third-party SPA source
# and no generated `managed/` output is committed to this repository, so a cold build needs
# GitHub + npm network access. See PROVENANCE.md.
#
# NO LEDGER PATCH, unlike the 2.x sibling. At this ref the template is already v8-native
# (ledger-v8 8.1.0 / midnight-js 4.1.1), which is the line the 1.x kernel runs, so
# `ledger-v9.patch` and its whole stage do not exist here. That is ASSERTED in stage 0 rather
# than assumed — if the frozen ref ever moved, the build fails there instead of shipping a
# silently mismatched bundle.
#
# NOTHING IS COMPILED HERE ANY MORE (00020 PR D, FRONTEND_REF=400880ce…). Up to `58ab921…`
# this image had a `compact` stage that compiled the template's own copy of the offer-files
# contract with compactc 0.31.0 and verified all 16 outputs against a committed
# src/contract/manifest.json. effectstream #922 — the frontend half of kernel #69 — DELETED
# that whole lane: src/contract/, scripts/build-contract.ts, the prebuild hook, the manifest,
# the Faucet screen, useContract/useMintReconciler, contractWallet/mintQueue, and the
# compact-js / compact-runtime / midnight-js-{contracts,fetch-zk-config,proof,indexer,
# private-state} dependencies. So the stage, the COMPACT_VERSION arg and the
# `toolchains[compact]` matrix entry are all gone with it, and stage 0 asserts their ABSENCE —
# a ref that moved BACKWARDS onto the contract line fails the build rather than producing a
# bundle that hunts for ZK assets the kernel no longer serves.
#
# RUNTIME CONFIG: src/config.ts resolves the API/batcher endpoints as
# window.API_BASE ?? VITE_API_BASE ?? http://<hostname>:9999 (and :3334), and
# upstream's api.getMidnightConfig (effectstream#912) adds window.{NODE,INDEXER,INDEXER_WS,
# PROOF_SERVER}_URI overrides on top of GET /v1/midnight/config. entrypoint.sh writes all six into /config.js from the
# container environment; each is skipped when empty, which leaves the template's
# hostname-relative defaults in charge (correct only on the default port block).
#
# BUILD-TIME CONFIG, and why two values cannot be runtime (00020 Q4). #920 added two knobs that
# src/config.ts reads from `import.meta.env` and exposes through NO `window.*` override:
#
#   VITE_MIDNIGHT_NETWORK_ID  the network id the page formats addresses with, parses offers
#                             with, hands `initialApi.connect()` (Lace) and passes to the
#                             built-in JS wallet's connectFromSeed(). Its default FLIPPED to
#                             `preprod` in #920, so an image that sets none is wrong for this
#                             stack in five places at once.
#   VITE_FAUCET_URL           the base URL of the external test-token service the SPA's Faucet
#                             LINK opens (the in-page Faucet TAB is gone). The `?network=` on
#                             that link is appended by the template from the network id above —
#                             see faucetUrl.ts — so the network id is the mechanism and the URL
#                             is only the host and port.
#
# Both are therefore build inputs, and this image is built per stack anyway
# (FRONTEND_IMAGE carries the run's tag). They are declared in the BUILD stage, after
# `bun install`, so a new port block re-runs `vite build` and nothing else.

# ── base images: index digests, not tags ─────────────────────────────────────
# All three are good official multiarch indexes (linux/amd64 + linux/arm64), so nothing here
# needs a `platform:` pin and both architectures build native. A tag is not an identity:
# `nginx:1.27-alpine` can be repointed at different bytes without one character of this
# repository changing.
#
# debian:trixie-slim and oven/bun:1.3.11 are the SAME digests images/offerfiles-kernel and
# images/celestia pin, deliberately — fewer distinct external identities in the stack, and
# ones already vetted. The bun pin in particular is load-bearing there (1.3.14 breaks the
# kernel's contract deploy); it is reused here for uniformity, not because this build needs
# that specific fix.
ARG DEBIAN_BASE=debian:trixie-slim@sha256:f6e2cfac5cf956ea044b4bd75e6397b4372ad88fe00908045e9a0d21712ae3ba
ARG BUN_BASE=oven/bun:1.3.11@sha256:0733e50325078969732ebe3b15ce4c4be5082f18c4ac1a0f0ca4839c2e4e42a7
ARG NGINX_BASE=nginx:1.27-alpine@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10

ARG FRONTEND_REPO=https://github.com/effectstream/effectstream.git
# The head of effectstream's `midnight-1` branch — the line maintained for midnight-node 1.x /
# ledger-v8 / @effectstream 0.1xx (Q14). Since effectstream#912 the branch also carries the
# browser-network change this image used to apply as a patch, so the tree is built UNMODIFIED:
# no ledger patch, no dependency patch, no URI patch.
ARG FRONTEND_REF=400880ceb6814738d1ae193dae18ad5128922edc
ARG FRONTEND_SUBTREE_SHA=a750cccd653f33306d3ff7249fe8d5853fbfafa6

# ── stage 0: the exact upstream subtree, unmodified ─────────────────────────
FROM ${DEBIAN_BASE} AS source

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

ARG FRONTEND_REPO
ARG FRONTEND_REF
ARG FRONTEND_SUBTREE_SHA

WORKDIR /upstream
RUN set -eux; \
    # A full 40-hex commit, always. `git fetch --depth 1 origin <sha>` refuses an abbreviated
    # sha and cannot see a branch move, which is the cheapest possible enforcement of the
    # repository's pinning rule.
    case "${FRONTEND_REF}" in \
      ????????????????????????????????????????) : ;; \
      *) echo "FAIL: FRONTEND_REF must be a full 40-character commit SHA, got '${FRONTEND_REF}'" >&2; exit 1 ;; \
    esac; \
    case "${FRONTEND_REF}" in *[!0-9a-f]*) echo "FAIL: FRONTEND_REF must be lowercase hex" >&2; exit 1 ;; esac; \
    git init -q .; \
    git remote add origin "${FRONTEND_REPO}"; \
    git fetch -q --depth 1 origin "${FRONTEND_REF}"; \
    actual="$(git rev-parse FETCH_HEAD)"; \
    test "${actual}" = "${FRONTEND_REF}"; \
    # The commit alone does not prove which BYTES of it were extracted. The subtree SHA does,
    # and it is a build arg so scripts/verify-compose-pins.sh binds it to the matrix too.
    tree="$(git rev-parse "FETCH_HEAD:templates/zswap-da")"; \
    if [ "${tree}" != "${FRONTEND_SUBTREE_SHA}" ]; then \
      echo "FAIL: templates/zswap-da is ${tree}, expected ${FRONTEND_SUBTREE_SHA}" >&2; exit 1; \
    fi; \
    git checkout -q FETCH_HEAD -- templates/zswap-da; \
    mkdir /src; \
    cp -a templates/zswap-da/. /src/; \
    printf '%s' "${actual}" > /.zswap-da-commit

# THE v8 ASSERTION. This repository ships no ledger-v9.patch because the template's CONTRACT
# lane at this ref is already on the ledger-v8 line the 1.x kernel runs. Assert it, both
# directions: the exact ledger-v8 pin must be present AND no ledger-v9 dependency may appear
# in package.json. A frozen ref that moved would otherwise produce a bundle proving against
# the wrong ledger, which fails much later and much less legibly.
RUN set -eux; \
    cd /src; \
    grep -q '"@midnight-ntwrk/ledger-v8": "8.1.0"' package.json; \
    if grep -q 'ledger-v9' package.json; then \
      echo "FAIL: the template now depends on ledger-v9; this repository targets the 1.x/v8 line" >&2; exit 1; \
    fi; \
    test -f LICENSE-APACHE; \
    test -f LICENSE-MIT

# THE CONTRACT LANE MUST BE ABSENT — asserted, not assumed (00020 PR D).
#
# `"@midnight-ntwrk/compact-runtime": "0.16.0"` used to be asserted one block up, beside the
# ledger pin. effectstream #922 REMOVED that dependency along with compact-js and the five
# midnight-js contract/proof/indexer/private-state packages, so keeping the old grep would have
# failed this build on a correct tree. Asserting the absence instead is the same guard pointed
# the other way, and it is the one that matters now: a ref moved BACKWARDS onto the contract
# line would otherwise build a bundle whose Faucet screen fetches proving keys from
# `GET /keys/*` — routes kernel #69 deleted, which `scripts/verify-frontend.sh` asserts answer
# 404. The failure would then surface in a browser, on a click, with no message.
RUN set -eux; \
    cd /src; \
    for gone in src/contract scripts/build-contract.ts src/screens/Faucet.tsx \
                src/hooks/useContract.ts src/services/contractWallet.ts \
                src/services/mintQueue.ts; do \
      if [ -e "${gone}" ]; then \
        echo "FAIL: ${gone} exists. effectstream #922 deleted the template's contract lane; a" >&2; \
        echo "      tree that still has it is BEFORE that merge, and this image has no Compact" >&2; \
        echo "      stage to compile it with. Check FRONTEND_REF (expected 400880ce… or later)." >&2; \
        exit 1; \
      fi; \
    done; \
    if grep -q '"prebuild"' package.json; then \
      echo "FAIL: package.json still has a prebuild hook (the contract compile)" >&2; exit 1; \
    fi; \
    if grep -q 'compact-runtime\|compact-js' package.json; then \
      echo "FAIL: package.json still depends on the Compact toolchain packages" >&2; exit 1; \
    fi

# THE TWO BUILD-TIME KNOBS #920 ADDED must exist in the tree we are about to build, or the
# values passed below are silently ignored and the SPA runs on `preprod` against an
# `undeployed` chain. Both markers are read out of src/config.ts, which is where the template
# resolves them; faucetUrl.ts is where the `?network=` is appended.
RUN set -eux; \
    cd /src; \
    grep -q 'VITE_MIDNIGHT_NETWORK_ID' src/config.ts; \
    grep -q 'VITE_FAUCET_URL' src/config.ts; \
    grep -q "searchParams.set('network'" src/faucetUrl.ts

# ── the OTHER half of "v8-native", which package.json alone does not show ────
#
# "v8-native" has to hold for the template's WALLET lane, not just its contract lane. On
# effectstream `main` it does not: from commit 98b2b78b ("bump @effectstream/* 0.104.0 ->
# 0.200.1") `@effectstream/{midnight-contracts,wallets}` pull `@midnightntwrk/ledger-v9` and the
# v9 wallet SDK, and on a live 1.x stack the in-page JS wallet then fails every sync event with
# `Wallet.Sync: … Failed to decode ledger event payload`, its balance stays 0 and offer
# create/take die with "Insufficient <token>" (measured at P3; the gasless faucet mint still
# worked). This image used to carry upstream's own reverse diff as a patch. It no longer needs
# to: FRONTEND_REF is the `midnight-1` branch, whose template is on the 0.104.0 (1.x) line
# natively — the same bytes the patch produced (verified blob-for-blob, Q14).
#
# The guards stay, because they are what turns "we pinned the right branch" into something the
# build proves: 0.104.0 present, no 0.200.x, and — the decisive one — nothing in the RESOLVED
# lockfile pulls ledger-v9. If the pinned ref ever drifts to the 2.x line, the build fails here
# instead of producing a bundle with two wasm ledgers and a wallet that cannot sync.
RUN set -eux; \
    cd /src; \
    grep -q '"@effectstream/midnight-contracts": "0.104.0"' package.json; \
    grep -q '"@effectstream/wallets": "0.104.0"' package.json; \
    if grep -q '0\.200\.' package.json; then \
      echo "FAIL: a 0.200.x @effectstream dependency is present; this ref is not on the 1.x line" >&2; exit 1; \
    fi; \
    if grep -q 'ledger-v9' bun.lock; then \
      echo "FAIL: the resolved lockfile contains ledger-v9; the wallet lane is not v8" >&2; exit 1; \
    fi

# The kernel's GET /v1/midnight/config reports the URIs the KERNEL dials — inside compose
# those are service hostnames (indexer, proof-server) on container ports. Upstream fixes both
# halves at api.getMidnightConfig, the single chokepoint every consumer goes through
# (effectstream#912, on midnight-1). This image no longer patches anything; it ASSERTS the
# pinned tree carries the fix — one marker per half — so a re-pin to a tree without it fails
# the build instead of shipping a SPA that dials compose hostnames.
RUN set -eux; \
    cd /src; \
    grep -q 'pageHost' src/services/api.ts; \
    grep -q "'proofServerUri'" src/services/api.ts

# BOTH identities are baked into the runtime image, not just the commit.
# scripts/verify-source-pins.sh reads them out of the built image and asserts them against
# config/artifact-decisions.json, so "which bytes is this?" is answerable from a running
# stack rather than from remembering how it was built. The subtree hash is the one that
# matters most here: a commit says which history, only the tree says which files.
ARG FRONTEND_SUBTREE_SHA
RUN printf '%s' "${FRONTEND_SUBTREE_SHA}" > /.zswap-da-subtree

# ── stage 1: build the SPA ───────────────────────────────────────────────────
#
# There is no longer a stage between `source` and this one. Up to `58ab921…` a `compact` stage
# fetched compactc 0.31.0 as a SHA-256-verified release asset, compiled
# src/contract/offer-files.compact, and handed the 16 generated files to the build, which
# verified them against the template's committed manifest before bundling. effectstream #922
# deleted the source, the manifest and the build script, so the stage compiled nothing and the
# `--verify-only` run had no manifest to read. Both are gone, and with them the COMPACT_VERSION
# build arg and the `compact` entry in config/artifact-decisions.json — this image no longer
# has a Compact toolchain of any kind.
FROM ${BUN_BASE} AS build

WORKDIR /src
COPY --from=source /src /src

# THE LOCKFILE AT THE PINNED COMMIT IS THE TESTED DEPENDENCY SET, and this step is what makes
# that true. It used to be a plain `bun install --frozen-lockfile`.
#
# AT `400880ce…` THAT COMMAND FAILS — on a correct tree, measured before this was written:
#
#     error: lockfile had changes, but lockfile is frozen
#
# effectstream #922 removed seven dependencies from package.json and from bun.lock's
# `workspaces` block, but left ONE resolved entry behind in the lockfile's `packages` map:
# `@midnight-ntwrk/midnight-js-fetch-zk-config-provider@4.1.1`, which nothing depends on any
# more. (The other six are still reachable transitively through
# `@effectstream/midnight-contracts` and `midnight-js-protocol`, so they are correct where
# they are.) `bun install` prunes that orphan, which is a change, which `--frozen-lockfile`
# refuses. The drift is upstream lockfile hygiene, not a version move: measured with
# `bun install --lockfile-only` on the extracted tree, the ENTIRE diff is the removal of that
# one entry and the blank line after it — 683 packages, no addition, no version change.
#
# So the guard is not dropped, it is made EXACT: install unfrozen, then require that the
# resolution ADDED nothing and CHANGED nothing, and that every line it removed is that one
# orphan. That is strictly stronger than `--frozen-lockfile` (which only says "no diff"), it
# still fails on a transitive publish, and it keeps working if upstream regenerates the
# lockfile — an EMPTY diff satisfies it too.
#
# DECLARED BEFORE THE TWO VITE ARGS ON PURPOSE: the faucet URL changes with every generated
# port block, and an ARG consumed above this line would invalidate the install layer and turn a
# port change into a full dependency re-resolution.
RUN set -eux; \
    cp bun.lock /bun.lock.pinned; \
    bun install; \
    diff -u /bun.lock.pinned bun.lock > /bun.lock.diff || true; \
    added="$(grep -E '^\+' /bun.lock.diff | grep -v '^\+\+\+' || true)"; \
    if [ -n "${added}" ]; then \
      echo "FAIL: bun install ADDED or CHANGED lockfile entries; the pinned resolution is not" >&2; \
      echo "      what this tree installs. Re-pin deliberately or fix the lockfile upstream." >&2; \
      echo "${added}" >&2; \
      exit 1; \
    fi; \
    removed="$(grep -E '^-' /bun.lock.diff | grep -v '^---' | grep -v '^-[[:space:]]*$' || true)"; \
    unexpected="$(printf '%s\n' "${removed}" | grep -v 'midnight-js-fetch-zk-config-provider' | grep . || true)"; \
    if [ -n "${unexpected}" ]; then \
      echo "FAIL: bun install pruned lockfile entries other than the known upstream orphan:" >&2; \
      echo "${unexpected}" >&2; \
      exit 1; \
    fi; \
    echo "OK: the resolved set matches the pinned lockfile$( [ -n "${removed}" ] && printf '%s' " (minus the one orphan #922 left behind)" )"; \
    rm -f /bun.lock.pinned /bun.lock.diff

# ── the two build-time values, and why they are checked here (00020 Q4) ──────
#
# Vite inlines `import.meta.env.VITE_*` as string literals at build time, taking them from
# process.env as well as from .env files, so an ENV in this stage is all it takes. What it does
# NOT do is complain about a missing one: an unset VITE_MIDNIGHT_NETWORK_ID silently selects
# `preprod` (the template's default since #920) and an unset VITE_FAUCET_URL silently selects
# the PUBLIC mint-test-tokens site. Both wrong answers look exactly like a working build, which
# is why they are asserted rather than defaulted-and-hoped.
#
# FRONTEND_NETWORK_ID is not meaningfully variable — this repository is a local `undeployed`
# devnet — so compose passes the literal and the check below refuses anything else. If a
# future stack ever needs another network, that is a deliberate edit here, not an env typo.
ARG FRONTEND_NETWORK_ID=undeployed
# The default is the DEFAULT PORT BLOCK's faucet, matching FAUCET_HOST_PORT=10500 in
# .env.example and `: "${FAUCET_HOST_PORT:=10500}"` in scripts/lib/common.sh. Every generated
# stack overrides it (scripts/pick-ports.sh emits FRONTEND_FAUCET_URL), and
# scripts/verify-frontend.sh asserts the SERVED bundle carries exactly the value this stack's
# env file names — so an image built for a different port block fails the gate instead of
# sending a person to a dead port.
#
# The `?network=undeployed` in it is DOCUMENTATION, not mechanism: src/faucetUrl.ts does
# `url.searchParams.set('network', <the network id>)`, so this parameter is overwritten with
# the value of FRONTEND_NETWORK_ID whatever it says here. It is carried anyway so that the
# baked string is byte-identical to the URL `up.sh` prints and docs/OPERATIONS.md documents.
ARG FRONTEND_FAUCET_URL=http://127.0.0.1:10500/?network=undeployed

RUN set -eux; \
    case "${FRONTEND_NETWORK_ID}" in \
      undeployed) : ;; \
      *) echo "FAIL: FRONTEND_NETWORK_ID must be 'undeployed' for this stack, got '${FRONTEND_NETWORK_ID}'" >&2; exit 1 ;; \
    esac; \
    case "${FRONTEND_FAUCET_URL}" in \
      http://*|https://*) : ;; \
      "") echo "FAIL: FRONTEND_FAUCET_URL is empty; the SPA would link to the PUBLIC faucet" >&2; exit 1 ;; \
      *) echo "FAIL: FRONTEND_FAUCET_URL must be an absolute http(s) URL, got '${FRONTEND_FAUCET_URL}'" >&2; exit 1 ;; \
    esac; \
    echo "building with VITE_MIDNIGHT_NETWORK_ID=${FRONTEND_NETWORK_ID} VITE_FAUCET_URL=${FRONTEND_FAUCET_URL}"

ENV VITE_MIDNIGHT_NETWORK_ID="${FRONTEND_NETWORK_ID}"
ENV VITE_FAUCET_URL="${FRONTEND_FAUCET_URL}"

# `build` = `tsc -b && vite build`. The `prebuild` hook that used to run the contract compile
# was deleted by #922, and stage 0 asserts it is gone.
RUN bun run build

# BOTH VALUES MUST BE IN THE EMITTED BUNDLE, not merely in this stage's environment. Vite only
# inlines what it recognises: a renamed variable, a changed envPrefix or a template that stopped
# reading the knob would leave the defaults in place, and the page would quietly run on preprod
# and link to the public faucet. The faucet URL is a unique, stack-specific literal, so it is
# matched exactly; the network id is matched as `"undeployed".trim()`, the shape config.ts's
# `(import.meta.env.VITE_MIDNIGHT_NETWORK_ID)?.trim()` compiles to once the literal is inlined.
#
# FRONTEND_FAUCET_URL is NOT re-declared here: an ARG stays in scope to the end of its stage,
# and a bare `ARG FRONTEND_FAUCET_URL` would reset it to the EMPTY string whenever the build
# does not pass one — and `grep -F ""` matches every file, which is a check that always passes.
RUN set -eux; \
    grep -rqF -- "${FRONTEND_FAUCET_URL}" /src/dist/assets \
      || { echo "FAIL: VITE_FAUCET_URL '${FRONTEND_FAUCET_URL}' is not in the built bundle" >&2; exit 1; }; \
    grep -rqF -- '"undeployed".trim()' /src/dist/assets \
      || { echo "FAIL: VITE_MIDNIGHT_NETWORK_ID was not inlined as 'undeployed' in the bundle" >&2; exit 1; }

# THE FIX MUST SURVIVE INTO THE BUNDLE, not merely into the source tree. Two markers, one
# per half of upstream's browser-network change (effectstream#912), greped out of the emitted assets: `([A-Z])` is the
# camelCase→SCREAMING_SNAKE regex of the override lane, `[^/:]+` the hostname-rewrite regex.
# Both are regex literals, which esbuild emits verbatim. Without this, a future bundler change
# that dropped dead-looking code would ship a SPA that silently dials compose hostnames.
RUN set -eux; \
    grep -rqF '([A-Z])' /src/dist/assets || { echo "FAIL: the URI-override lane is not in the bundle" >&2; exit 1; }; \
    grep -rqF '[^/:]+'  /src/dist/assets || { echo "FAIL: the hostname rewrite is not in the bundle" >&2; exit 1; }

# ── stage 2: nginx serving dist/ on :10600 ───────────────────────────────────
FROM ${NGINX_BASE}

COPY --from=build  /src/dist /usr/share/nginx/html
COPY --from=source /.zswap-da-commit  /.zswap-da-commit
COPY --from=source /.zswap-da-subtree /.zswap-da-subtree
COPY --from=source /src/LICENSE-APACHE /usr/share/licenses/zswap-da/LICENSE-APACHE
COPY --from=source /src/LICENSE-MIT    /usr/share/licenses/zswap-da/LICENSE-MIT
COPY PROVENANCE.md /usr/share/licenses/zswap-da/PROVENANCE.md

# /config.js is generated at container start (entrypoint.sh); reference it BEFORE the bundle
# so window.API_BASE and friends are already set when src/config.ts evaluates.
RUN set -eux; \
    sed -i 's|<script type="module"|<script src="/config.js"></script><script type="module"|' \
      /usr/share/nginx/html/index.html; \
    grep -q 'config.js' /usr/share/nginx/html/index.html

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY entrypoint.sh /docker-entrypoint-frontend.sh
RUN set -eux; \
    chmod 0755 /docker-entrypoint-frontend.sh; \
    rm -f /etc/nginx/conf.d/default.conf.default; \
    # wasm must be served as application/wasm or streaming instantiation refuses the module.
    # The stock mime.types has carried it since nginx 1.21.5, so this asserts rather than
    # patches: a second `types` block in the same context is a config error, and silently
    # serving wasm as octet-stream is a page that loads and then cannot prove anything.
    grep -qE '^[[:space:]]*application/wasm[[:space:]]+wasm;' /etc/nginx/mime.types \
      || { echo "FAIL: this nginx image's mime.types has no application/wasm mapping" >&2; exit 1; }; \
    nginx -t

EXPOSE 10600
ENTRYPOINT ["/docker-entrypoint-frontend.sh"]
