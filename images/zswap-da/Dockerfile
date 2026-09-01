# zswap-da — the offer-files trading SPA (React/Vite), served by nginx on container :10600,
# talking to the offer-files kernel API (:9999) and the batcher (:3334).
#
# SOURCE IS FETCHED DIRECTLY from effectstream/effectstream at an immutable full commit and
# the `templates/zswap-da` subtree SHA is verified before checkout. No third-party SPA source
# and no generated `managed/` output is committed to this repository, so a cold build needs
# GitHub + npm network access. See PROVENANCE.md.
#
# NO LEDGER PATCH, unlike the 2.x sibling. At this ref the template is already v8-native
# (ledger-v8 8.1.0 / midnight-js 4.1.1 / compact-js 2.5.1 / compact-runtime 0.16.0), which is
# the line the 1.x kernel runs, so `ledger-v9.patch` and its whole stage do not exist here.
# That is ASSERTED in stage 0 rather than assumed — if the frozen ref ever moved, the build
# fails there instead of shipping a silently mismatched bundle.
#
# THE CONTRACT IS COMPILED HERE from the template's tracked Compact source, with compactc
# 0.31.0 — the version the template's own build script pins and its committed manifest.json
# verifies byte-for-byte. The kernel image compiles the SAME source with 0.30.0 for its own
# runtime; two toolchains, one deliberate split, both recorded in
# config/artifact-decisions.json. The generated artifacts are build-only: the runtime image
# receives only dist/.
#
# RUNTIME CONFIG: src/config.ts resolves the API/batcher endpoints as
# window.API_BASE ?? VITE_API_BASE ?? http://<hostname>:9999 (and :3334), and
# browser-network-urls.patch adds window.{NODE,INDEXER,INDEXER_WS,PROOF_SERVER}_URI overrides
# on top of GET /v1/midnight/config. entrypoint.sh writes all six into /config.js from the
# container environment; each is skipped when empty, which leaves the template's
# hostname-relative defaults in charge (correct only on the default port block).

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
ARG FRONTEND_REF=332503c8f9216143a8c805f2a0acbcfd39e5a21d
ARG FRONTEND_SUBTREE_SHA=1f63d7eedc9a8aff729b7fe026486cb89cb618de
ARG COMPACT_VERSION=0.31.0

# ── stage 0: the exact upstream subtree, plus the one adaptation patch ───────
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
    grep -q '"@midnight-ntwrk/compact-runtime": "0.16.0"' package.json; \
    test -f LICENSE-APACHE; \
    test -f LICENSE-MIT

# ── the OTHER half of "v8-native", which package.json alone does not show ────
#
# "The template is v8-native at this ref" is true of its CONTRACT lane and FALSE of its WALLET
# lane. At the frozen ref `@effectstream/{midnight-contracts,wallets}` are 0.200.1 — the
# Midnight 2.x line — whose closure is `@midnightntwrk/ledger-v9` 1.0.0-rc.3 plus the v9
# wallet SDK. MEASURED CONSEQUENCE on a live 1.x stack: the in-page JS wallet connects, then
# its sync loop fails every event with `Wallet.Sync: … Failed to decode ledger event payload`,
# so its balance stays 0 forever and offer create/take die with "Insufficient <token>". The
# faucet mint still works, because it is gasless — the batcher balances and submits, and the
# browser only proves the contract call with midnight-js 4.1.1 / ledger-v8.
#
# This patch is UPSTREAM'S OWN DIFF, not our invention: it is exactly
# `git diff 332503c8 02a04de3 -- templates/zswap-da`, i.e. the reverse of effectstream commit
# 98b2b78b ("bump @effectstream/* 0.104.0 -> 0.200.1"). Between those two commits the template
# subtree differs ONLY in package.json (2 lines) and bun.lock — no source file changes at all.
# 0.104.0 is the 1.x line: `@effectstream/midnight-contracts@0.104.0` depends on
# `@midnight-ntwrk/ledger-v8@8.1.0` and `wallet-sdk-facade@4.1.0`, and the resulting lockfile
# contains ZERO references to ledger-v9 — which also collapses the bundle to ONE wasm ledger
# instead of two.
#
# See plan question Q14 for the alternative (moving FRONTEND_REF to 02a04de3 instead of
# patching), which is cleaner but changes an identity the spec names.
COPY effectstream-1x-line.patch /tmp/effectstream-1x-line.patch
RUN set -eux; \
    cd /src; \
    git apply --check /tmp/effectstream-1x-line.patch; \
    git apply /tmp/effectstream-1x-line.patch; \
    grep -q '"@effectstream/midnight-contracts": "0.104.0"' package.json; \
    grep -q '"@effectstream/wallets": "0.104.0"' package.json; \
    if grep -q '0\.200\.' package.json; then \
      echo "FAIL: a 0.200.x @effectstream dependency survived the 1.x-line patch" >&2; exit 1; \
    fi; \
    # The decisive one. The wallet lane is v8-only if and only if nothing in the resolved
    # dependency graph pulls ledger-v9 — and the lockfile is where that is visible.
    if grep -q 'ledger-v9' bun.lock; then \
      echo "FAIL: the resolved lockfile still contains ledger-v9; the wallet lane is not v8" >&2; exit 1; \
    fi

# The kernel's GET /v1/midnight/config reports the URIs the KERNEL dials — inside compose
# those are service hostnames (indexer, proof-server) on container ports. The patch fixes both
# halves at api.getMidnightConfig, the single chokepoint every consumer goes through. Applied
# fail-closed: --check first, then guard greps for one marker of each half, so a patch that
# stops applying breaks the build instead of quietly no-opping.
COPY browser-network-urls.patch /tmp/browser-network-urls.patch
RUN set -eux; \
    cd /src; \
    git apply --check /tmp/browser-network-urls.patch; \
    git apply /tmp/browser-network-urls.patch; \
    grep -q 'pageHost' src/services/api.ts; \
    grep -q "'proofServerUri'" src/services/api.ts

# BOTH identities are baked into the runtime image, not just the commit.
# scripts/verify-source-pins.sh reads them out of the built image and asserts them against
# config/artifact-decisions.json, so "which bytes is this?" is answerable from a running
# stack rather than from remembering how it was built. The subtree hash is the one that
# matters most here: a commit says which history, only the tree says which files.
ARG FRONTEND_SUBTREE_SHA
RUN printf '%s' "${FRONTEND_SUBTREE_SHA}" > /.zswap-da-subtree

# ── stage 1: compile the matching Compact bindings and keys ──────────────────
# Fetched as a release asset and SHA-256 verified, rather than run through the `compact`
# version manager whose resolution is an unpinnable network lookup. `compactc <in> <out>` is
# exactly what `compact compile +V <in> <out>` dispatches to.
FROM ${DEBIAN_BASE} AS compact

ARG COMPACT_VERSION
ARG TARGETARCH
ARG COMPACT_REPO=midnightntwrk/compact
# SHA-256 of each release asset, from the GitHub release API's own `digest` field
# (2026-09-01). These, not the URL, are the compiler's identity: a release asset can be
# re-uploaded under the same name. midnightntwrk/compact and LFDT-Minokawa/compact publish
# byte-identical assets for this tag (verified — same sha256, same sizes); the former is used
# because it is where the toolchain manager itself is published and where the kernel image
# already pins.
ARG COMPACT_SHA256_AMD64=ddbb4bb227c6a9c67098e65663648d8647097404ae094fdc0abe660839ea3ee8
ARG COMPACT_SHA256_ARM64=9ead84322fb0c64aac6f94f12cd01eb011c1f3d0321d9fabc6a52b419c3dd6c6

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
    # The pin says 0.31.0; make the BINARY say so too. A renamed or re-uploaded asset would
    # otherwise be caught by nothing until a verifier key was rejected at runtime.
    ver="$(/opt/compactc/compactc --version 2>&1 || true)"; \
    echo "compactc reports: ${ver}"; \
    case "${ver}" in \
      *"${COMPACT_VERSION}"*) : ;; \
      *) echo "FAIL: compactc does not report version ${COMPACT_VERSION}: ${ver}" >&2; exit 1 ;; \
    esac

# Only the contract source, so an edit anywhere else in the template does not invalidate this
# layer. HOME and XDG_CACHE_HOME are redirected because the default HOME is /root and a cache
# written there would be baked into a layer nothing reads. (Unlike the 2.x sibling's contract,
# this one needs no universal-SRS download: three circuits, measured at ~9 s total.)
COPY --from=source /src/src/contract/offer-files.compact /contract/offer-files.compact
RUN set -eux; \
    HOME=/tmp XDG_CACHE_HOME=/tmp/zk-cache \
      /opt/compactc/compactc /contract/offer-files.compact /contract/managed/; \
    test -d /contract/managed/contract; \
    test -d /contract/managed/keys; \
    test -d /contract/managed/zkir

# ── stage 2: verify the pinned manifest, then build ──────────────────────────
FROM ${BUN_BASE} AS build

WORKDIR /src
COPY --from=source /src /src
COPY --from=compact /contract/managed /src/src/contract/managed

# Frozen: the lockfile at the pinned commit IS the tested dependency set. `--frozen-lockfile`
# turns "a transitive dependency published a new version" from a silent difference into a
# build failure.
RUN bun install --frozen-lockfile

# The template does not track generated managed/ output, so verify Docker's freshly compiled
# artifacts against the trusted checked-in manifest — 16 files plus the source hash — BEFORE
# anything is bundled. `compact compile` is deterministic, so this is an exact check, not a
# heuristic: a mismatch means the source was edited or the compiler version differs. Routine
# builds must never self-bless compiler output via --update-manifest.
RUN bun run scripts/build-contract.ts --verify-only

# `build` = `tsc -b && vite build`; its `prebuild` hook re-runs the same manifest verification
# (and skips the compile, because managed/ is already present).
RUN bun run build

# THE PATCH MUST SURVIVE INTO THE BUNDLE, not merely into the source tree. Two markers, one
# per half of browser-network-urls.patch, greped out of the emitted assets: `([A-Z])` is the
# camelCase→SCREAMING_SNAKE regex of the override lane, `[^/:]+` the hostname-rewrite regex.
# Both are regex literals, which esbuild emits verbatim. Without this, a future bundler change
# that dropped dead-looking code would ship a SPA that silently dials compose hostnames.
RUN set -eux; \
    grep -rqF '([A-Z])' /src/dist/assets || { echo "FAIL: the URI-override lane is not in the bundle" >&2; exit 1; }; \
    grep -rqF '[^/:]+'  /src/dist/assets || { echo "FAIL: the hostname rewrite is not in the bundle" >&2; exit 1; }

# ── stage 3: nginx serving dist/ on :10600 ───────────────────────────────────
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
