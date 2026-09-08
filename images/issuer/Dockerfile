# issuer — THIS STACK'S OWN TOKEN ISSUER, built from the public
# effectstream/mint-test-tokens repository at an immutable full commit.
#
# ── WHY IT EXISTS ────────────────────────────────────────────────────────────
# Until 00020 the stack's only token source was the offer-files kernel's own faucet contract
# (`offerfiles-deploy` deployed it and minted DEVA/DEVB/DEVU). Kernel #69 removed that
# contract: on the public networks tokens now come from mint-test-tokens' hosted registry, and
# upstream's own words are that "a public faucet cannot fund a fresh local chain". So an
# `undeployed` stack has to issue its own — and mint-test-tokens supports exactly that
# (`MN_NETWORK=undeployed`) on this repository's exact 1.x line: ledger-v8 8.1.0,
# compact-runtime 0.16.0, compactc 0.31.1, midnight-js 4.1.1.
#
# ── ONE BUILD, TWO RUNTIME TARGETS ───────────────────────────────────────────
#
#   --target runtime  the node runtime carrying the pinned tree, its root node_modules, `git`
#                     and `psql`. Three roles, one per entrypoint:
#                       entrypoint-deploy.sh     the `issuer-deploy` one-shot: fund the issuer
#                                                seed from genesis-1 under the genesis lock,
#                                                register that NIGHT for DUST, then run the
#                                                repository's own v1 deploy and publish
#                                                metadata.undeployed.json.
#                       entrypoint-registrar.sh  the `issuer-registrar` one-shot: teach the
#                                                offer-files kernel the six colours (UPDATE by
#                                                name, then POST /v1/known-tokens).
#                       entrypoint-fund.sh       `issuer-fund <TOKEN> <base-units> <seed>` —
#                                                the headless exact mint every other profile's
#                                                provisioning calls.
#                     A fourth, entrypoint-registry.sh, validates and dumps the registry for
#                     ./verify.sh.
#   --target faucet   nginx serving the repository's built `frontend/dist` on container :10500,
#                     with the stack's own registry mounted in beside it. Answers
#                     `/?network=undeployed`.
#
# SOURCE IS FETCHED DIRECTLY from effectstream/mint-test-tokens at a full commit. No upstream
# source and no generated artifact is committed to this repository, so a cold build needs
# GitHub + npm network access. See PROVENANCE.md.
#
# NO PATCH OF ANY KIND. Every integration knob this profile stands on — `MN_NETWORK=undeployed`
# with env-overridable endpoints, `MN_SEED_FILE`, `MN_METADATA_OUTPUT_DIR`, `MN_REDEPLOY_STALE`,
# the resume journal, and a `mint(recipient, amount, nonce)` circuit any caller may invoke for
# any positive amount — is UPSTREAM. This build ASSERTS each of them is present at the pin, so
# a re-pin to a tree without them fails HERE rather than as a one-shot that hangs against
# 127.0.0.1 or a faucet that can only hand out fixed presets.
#
# ── THE .git DIRECTORY IS PART OF THE RUNTIME, NOT AN ACCIDENT ───────────────
# `scripts/lib/deployment-provenance.ts` runs `git rev-parse HEAD`, `git cat-file -e
# <rev>:<path>`, `git diff --name-only <rev> -- <paths>` and both `git ls-files --others`
# variants over `contracts/v1/{shielded-token,unshielded-token}.compact` and
# `contracts/v1/managed/{shielded,unshielded}` BEFORE it will submit a deployment, and records
# the resolved commit in the registry as `artifact.sourceRevision`. A runtime image without a
# git repository at the pin cannot deploy at all. That is a feature — the registry this stack
# publishes names the exact source revision its verifier keys came from — so the image keeps
# `.git`, detached exactly at ISSUER_REF, and writes nothing under `contracts/`.

# ── base images: index digests, not tags ─────────────────────────────────────
# DEBIAN_BASE and NGINX_BASE are the SAME two digests images/shielded-night, images/zswap-da
# and images/offerfiles-kernel already pin — fewer distinct external identities in the stack,
# and ones already vetted.
#
# NODE, in two flavours of ONE version (24.15.0 — the version upstream's own verified release
# export uses, `node:24.15.0-bookworm`, and above both `engines` floors in the tree: root
# `>=22`, frontend `>=20.19`, frontend/protocols/v2 `>=22.12`):
#   NODE_BUILD_BASE   the FULL image (buildpack-deps), because four `npm ci` runs in one tree
#                     must not fail on a package that needs a C toolchain for a postinstall.
#   NODE_RUNTIME_BASE the SLIM image, which is what actually ships. Both are Debian TRIXIE, so
#                     the runtime's `postgresql-client` is 17.x — the same major as this
#                     stack's `postgres:17-alpine` server, exactly as images/shielded-night
#                     reasoned when it added psql for the sNight patch.
# Both are good official multiarch indexes (linux/amd64 + linux/arm64), so nothing here needs a
# `platform:` pin.
ARG DEBIAN_BASE=debian:trixie-slim@sha256:f6e2cfac5cf956ea044b4bd75e6397b4372ad88fe00908045e9a0d21712ae3ba
ARG NODE_BUILD_BASE=node:24.15.0-trixie@sha256:8202a46483627d14c75c8078d8c1b1d8ec14b792390c7001adb4f698724c4ca9
ARG NODE_RUNTIME_BASE=node:24.15.0-trixie-slim@sha256:291be77873bc04731968cacf82f0fcef17cee8cf200c6b6951e2bcab41560eb7
ARG NGINX_BASE=nginx:1.27-alpine@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10

ARG ISSUER_REPO=https://github.com/effectstream/mint-test-tokens.git
ARG ISSUER_REF=7ecad008b07acb2a491d8291e05455cbd638910f
# NOT a free choice: the pinned tree's `contracts/v1/managed/*/compiler/contract-info.json`
# records `"compiler-version": "0.31.1"` and `scripts/v1-deploy.ts` hard-codes
# EMBEDDED_COMPILER_VERSION = "0.31.1" plus a COMPATIBILITY snapshot it writes into every
# registry record. Stage `source` asserts both still say so, so this ARG and the source can
# never drift apart silently. It is the SAME compiler images/shielded-night pins, and therefore
# the same release asset and the same two SHA-256s.
ARG COMPACT_VERSION=0.31.1

# ── stage 0: the exact upstream tree, and what it must contain ───────────────
FROM ${DEBIAN_BASE} AS source

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

ARG ISSUER_REPO
ARG ISSUER_REF

WORKDIR /src
RUN set -eux; \
    # A full 40-hex commit, always. `git fetch --depth 1 origin <sha>` refuses an abbreviated
    # sha and cannot see a branch move, which is the cheapest possible enforcement of this
    # repository's pinning rule.
    case "${ISSUER_REF}" in \
      ????????????????????????????????????????) : ;; \
      *) echo "FAIL: ISSUER_REF must be a full 40-character commit SHA, got '${ISSUER_REF}'" >&2; exit 1 ;; \
    esac; \
    case "${ISSUER_REF}" in *[!0-9a-f]*) echo "FAIL: ISSUER_REF must be lowercase hex" >&2; exit 1 ;; esac; \
    git init -q .; \
    git remote add origin "${ISSUER_REPO}"; \
    git fetch -q --depth 1 origin "${ISSUER_REF}"; \
    actual="$(git rev-parse FETCH_HEAD)"; \
    test "${actual}" = "${ISSUER_REF}"; \
    # DETACHED AT THE PIN, not `checkout FETCH_HEAD -- .`: the deploy runner reads
    # `git rev-parse HEAD` when SOURCE_REVISION is unset, and a repository whose HEAD is an
    # unborn branch would make it resolve nothing.
    git checkout -q --detach FETCH_HEAD; \
    test "$(git rev-parse HEAD)" = "${ISSUER_REF}"; \
    test -z "$(git status --porcelain)"; \
    printf '%s' "${actual}" > /.issuer-commit

# THE TWO EXTRA COMMITS THE FRONTEND BUILD CANNOT DO WITHOUT.
#
# `frontend/scripts/verify-client-artifacts.mjs` hashes `contracts/<profile>/managed/<privacy>`
# TWICE — once from the working tree and once from the Git objects of the revision named in
# `frontend/client-artifacts.json` — and refuses to build unless the two agree with the
# declared digest. Those revisions are OLDER than the pin, so a plain `--depth 1` fetch of
# ISSUER_REF does not carry their trees and the build fails with "Client artifact source is
# missing …". Upstream documents exactly this ("A shallow or partial CI checkout must fetch
# those pinned commits and their objects before running the build. Missing objects deliberately
# fail verification; the verifier does not fetch from the network or bypass a missing pin").
#
# The revisions are READ OUT OF THE PINNED FILE rather than pinned again here: a second copy of
# them in this Dockerfile could disagree with the manifest the verifier actually reads, and the
# verifier would then fail on the manifest's value while this build looked correct.
RUN set -eux; \
    cd /src; \
    revs="$(sed -n 's/.*"sourceRevision"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' \
              frontend/client-artifacts.json | sort -u)"; \
    test -n "${revs}"; \
    echo "client-artifact revisions to fetch: ${revs}"; \
    for rev in ${revs}; do \
      git fetch -q --depth 1 origin "${rev}"; \
      git cat-file -e "${rev}^{commit}"; \
    done; \
    # The pin's own HEAD must still be the checked-out commit after those fetches.
    test "$(git rev-parse HEAD)" = "$(cat /.issuer-commit)"

# ── the v1 line, asserted in both directions ─────────────────────────────────
#
# This repository's core is node 1.0.1 / indexer 4.3.3 / proof-server 8.1.0 — the ledger-v8
# line — and the issuer's DEPLOY runtime is the tree's ROOT dependency graph. Two ledger wasm
# instances in one graph fail `instanceof` during proving, hours later and nowhere near the
# cause, so the root install is checked rather than trusted.
#
# `frontend/protocols/v2` DOES depend on `@midnightntwrk/ledger-v9`, and that is CORRECT and
# must not be "fixed": upstream installs the three browser profiles as ISOLATED package roots
# with their own lockfiles precisely so the 1.x and 2.x graphs are never deduplicated into one
# incompatible runtime (frontend/README.md says so). The assertion is therefore scoped to the
# root graph and to `frontend/protocols/v1`, and the v2 profile is asserted to be SEPARATE
# rather than absent.
RUN set -eux; \
    cd /src; \
    grep -q '"@midnight-ntwrk/ledger-v8": "8.1.0"' package.json; \
    grep -q '"@midnight-ntwrk/compact-runtime": "0.16.0"' package.json; \
    grep -q '"@midnight-ntwrk/midnight-js-contracts": "4.1.1"' package.json; \
    grep -q '"@midnight-ntwrk/ledger-v8": "8.1.0"' frontend/protocols/v1/package.json; \
    grep -q '"@midnight-ntwrk/compact-runtime": "0.16.0"' frontend/protocols/v1/package.json; \
    for f in package.json package-lock.json frontend/protocols/v1/package.json; do \
      if grep -q '"@midnightntwrk/ledger-v9"' "$f"; then \
        echo "FAIL: ${f} depends on @midnightntwrk/ledger-v9; the issuer's deploy runtime is the 1.x/v8 line" >&2; exit 1; \
      fi; \
    done; \
    # …and the v2 browser profile really is its own package root with its own lockfile, which
    # is what keeps the line above true at build time.
    test -f frontend/protocols/v2/package.json; \
    test -f frontend/protocols/v2/package-lock.json; \
    grep -q '"@midnightntwrk/ledger-v9"' frontend/protocols/v2/package.json \
      || { echo "FAIL: frontend/protocols/v2 no longer carries its own ledger-v9 — the isolation this build reasons about has changed" >&2; exit 1; }

# THE COMPILER THE TREE ITSELF NAMES must be the one this image fetches, stated in two
# independent places by upstream, and both are checked. A COMPACT_VERSION that disagreed would
# fail later as an inscrutable diff of binary keys rather than as the version mismatch it is.
ARG COMPACT_VERSION
RUN set -eux; \
    cd /src; \
    grep -q "\"compiler\": \"${COMPACT_VERSION}\"" compatibility.json \
      || { echo "FAIL: compatibility.json's v1 profile does not name compiler ${COMPACT_VERSION}" >&2; \
           sed -n '1,12p' compatibility.json >&2; exit 1; }; \
    grep -q "EMBEDDED_COMPILER_VERSION = \"${COMPACT_VERSION}\"" scripts/v1-deploy.ts \
      || { echo "FAIL: scripts/v1-deploy.ts does not embed compiler ${COMPACT_VERSION}" >&2; exit 1; }; \
    for p in shielded unshielded receiver; do \
      grep -q "\"compiler-version\": \"${COMPACT_VERSION}\"" "contracts/v1/managed/${p}/compiler/contract-info.json" \
        || { echo "FAIL: contracts/v1/managed/${p} was not compiled with ${COMPACT_VERSION}" >&2; exit 1; }; \
      grep -q '"runtime-version": "0.16.0"' "contracts/v1/managed/${p}/compiler/contract-info.json" \
        || { echo "FAIL: contracts/v1/managed/${p} does not embed compact-runtime 0.16.0" >&2; exit 1; }; \
    done

# ── the integration knobs this profile is built on ───────────────────────────
#
# Each is asserted at its source of truth, by the name the demo stack actually uses, so a
# re-pin that removed one fails HERE and names it — instead of appearing as a one-shot that
# times out against 127.0.0.1, a faucet that can only mint fixed presets, or a second `up.sh`
# that silently redeploys six contracts.
RUN set -eux; \
    cd /src; \
    # 1. `undeployed` with ENV-OVERRIDABLE endpoints. Upstream's `undeployed` defaults are
    #    loopback, and inside a container loopback is this container.
    for v in MN_NODE_URL MN_NODE_WS_URL MN_INDEXER_URL MN_INDEXER_WS_URL MN_PROOF_SERVER_URL; do \
      grep -q "$v" scripts/lib/network-config.ts \
        || { echo "FAIL: scripts/lib/network-config.ts does not honour ${v}" >&2; exit 1; }; \
    done; \
    grep -q '"undeployed"' scripts/lib/network-config.ts; \
    # 2. THE SEED ARRIVES AS A FILE, never as an argument or an environment value. That is what
    #    lets this stack keep the seed off every command line and out of `docker inspect`.
    grep -q 'MN_SEED_FILE' scripts/v1-deploy.ts; \
    grep -q '32 or 64 bytes of hexadecimal master seed' scripts/lib/wallet-seed.ts; \
    # 3. The registry goes to a DIRECTORY this stack chooses (a shared volume), under the fixed
    #    filename every consumer reopens by path.
    grep -q 'MN_METADATA_OUTPUT_DIR' scripts/v1-deploy.ts; \
    # Single-quoted so the shell leaves the template literal alone; `metadataOutputPath()` is
    # the ONE function that decides the filename every consumer of this stack reopens by path.
    grep -q 'metadataOutputPath' scripts/lib/registry-publisher.ts; \
    grep -qF 'networkKey}.json' scripts/lib/registry-publisher.ts \
      || { echo "FAIL: registry-publisher.ts no longer writes metadata.<network>.json" >&2; exit 1; }; \
    # 4. RESUME, and the explicit confirmation a chain reset needs. Without these a second
    #    `./up.sh` would redeploy six contracts and orphan every coin already minted.
    grep -q 'MN_REDEPLOY_STALE' scripts/v1-deploy.ts; \
    grep -q 'MN_CONFIRM_NO_DEPLOYMENT' scripts/v1-deploy.ts; \
    grep -q 'markRegistryStale' scripts/lib/registry-publisher.ts; \
    # 5. THE MINT CIRCUIT TAKES A CALLER-CHOSEN AMOUNT AND AN ARBITRARY RECIPIENT. This is the
    #    whole basis of `issuer-fund`: without it the only mint available would be the site's
    #    fixed faucet preset, and no automation could size a coin.
    grep -q 'export circuit mint' contracts/v1/shielded-token.compact; \
    grep -q 'export circuit mint' contracts/v1/unshielded-token.compact; \
    grep -q 'Uint<64>' contracts/v1/shielded-token.compact; \
    grep -q 'additionalCoinEncPublicKeyMappings' scripts/v1-mint-wallet-test.ts \
      || { echo "FAIL: the runner no longer maps the recipient's encryption key; a third-party shielded mint would be undiscoverable" >&2; exit 1; }; \
    # 6. THE SIX CANONICAL TOKENS, by symbol and decimals, in the canonical order the registry
    #    and this stack's registrar both walk.
    for t in '"twBTC"' '"twETH"' '"twUSDC"' '"twUSDM"' '"utwUSDC"' '"utwBTC"'; do \
      grep -q "symbol: ${t}" packages/registry/src/tokens.ts \
        || { echo "FAIL: packages/registry/src/tokens.ts no longer defines ${t}" >&2; exit 1; }; \
    done; \
    n="$(grep -c "symbol: \"" packages/registry/src/tokens.ts)"; \
    test "${n}" -eq 6 || { echo "FAIL: expected exactly 6 canonical token definitions, found ${n}" >&2; exit 1; }; \
    # …and their DECIMALS, because every price and every mint amount in the rest of this stack
    # is scaled by them. A silent change from 8 to 9 here would be wrong by a factor of ten in
    # verify-kernel's per-base-unit assertion and in every `issuer-fund` a phase-C one-shot makes.
    grep -q "symbol: \"twBTC\", name: \"Test-wrapped BTC\", decimals: 8," packages/registry/src/tokens.ts; \
    grep -q "symbol: \"twETH\", name: \"Test-wrapped ETH\", decimals: 18," packages/registry/src/tokens.ts; \
    grep -q "symbol: \"twUSDC\", name: \"Test-wrapped USDC\", decimals: 6," packages/registry/src/tokens.ts; \
    grep -q "symbol: \"twUSDM\", name: \"Test-wrapped USDM\", decimals: 6," packages/registry/src/tokens.ts; \
    grep -q "symbol: \"utwUSDC\", name: \"Unshielded-test-wrapped USDC\", decimals: 6," packages/registry/src/tokens.ts; \
    grep -q "symbol: \"utwBTC\", name: \"Unshielded-test-wrapped BTC\", decimals: 8," packages/registry/src/tokens.ts; \
    # The unshielded pair really is unshielded — the registrar posts `kind` from this and the
    # kernel rejects a cross-layer offer, so a privacy flip would surface as an unexplainable
    # refusal much later.
    grep -q "symbol: \"utwUSDC\", name: \"Unshielded-test-wrapped USDC\", decimals: 6, privacy: \"unshielded\"" packages/registry/src/tokens.ts; \
    grep -q "symbol: \"utwBTC\", name: \"Unshielded-test-wrapped BTC\", decimals: 8, privacy: \"unshielded\"" packages/registry/src/tokens.ts; \
    # 7. The static site's header policy, which images/issuer/nginx.conf transcribes. Pinned by
    #    CONTENT so a re-pin that changes the policy fails here instead of silently leaving the
    #    nginx config describing a policy upstream no longer has.
    echo '9396e4e035167adebc5285bde63bc7a97d0bb1250e22075a4a964ece147db5a6  frontend/public/_headers' \
      | sha256sum -c - \
      || { echo "FAIL: frontend/public/_headers changed at this pin — re-read it and update images/issuer/nginx.conf, then update this digest" >&2; \
           cat frontend/public/_headers >&2; exit 1; }

# ── stage 1: recompile the v1 contracts, and prove they are the committed ones ─
# Fetched as a release asset and SHA-256 verified, rather than run through the `compact`
# version manager whose resolution is an unpinnable network lookup. `compactc <in> <out>` is
# exactly what `compact compile +V <in> <out>` dispatches to.
#
# THIS STAGE PRODUCES NO ARTIFACT THE RUNTIME USES, and that is deliberate. images/shielded-night
# copies its freshly compiled output forward so that "what the page serves" and "what this build
# compiled" are the same bytes by construction. Here the opposite is required: the deploy runner
# demands that `contracts/v1/managed/` be byte-identical to the pinned COMMIT (it re-hashes the
# directory and records the digest in the registry, and refuses on any working-tree difference),
# so the committed bytes must be the ones that ship. The equality is proven instead — which is
# the same guarantee, reached from the other side.
FROM ${DEBIAN_BASE} AS compact

ARG COMPACT_VERSION
ARG TARGETARCH
ARG COMPACT_REPO=midnightntwrk/compact
# SHA-256 of each release asset, from the GitHub release API's own `digest` field. THE SAME TWO
# VALUES images/shielded-night pins, because it is the same version of the same compiler from
# the same release — verified locally on 2026-09-08 (the amd64 asset downloaded here reported
# `0.31.1` and reproduced this tree's committed artifacts byte-for-byte). These, not the URL,
# are the compiler's identity: a release asset can be re-uploaded under the same name.
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
    # build stage is exactly what the matrix's forbiddenAssetSubstrings list exists to prevent;
    # assert it cannot happen here either.
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
    ver="$(/opt/compactc/compactc --version 2>&1 || true)"; \
    echo "compactc reports: ${ver}"; \
    case "${ver}" in \
      *"${COMPACT_VERSION}"*) : ;; \
      *) echo "FAIL: compactc does not report version ${COMPACT_VERSION}: ${ver}" >&2; exit 1 ;; \
    esac

# THE SOURCE PATH IS PART OF THE OUTPUT, which is not obvious and cost images/shielded-night a
# build to discover: compactc records the input path it was given, verbatim, in the emitted
# source map. This tree's committed map says
#
#   "sourceRoot": "../../../../../", "sources": ["contracts/v1/shielded-token.compact", …]
#
# so the compile must be invoked FROM THE REPOSITORY ROOT as
# `compactc contracts/v1/<name>.compact contracts/v1/managed/<name>/`. Any other cwd or path
# spelling produces artifacts that are byte-identical in every ZK key and differ in two lines
# of the map — which would turn the assertion below from exact into "everything except the map".
COPY --from=source /src/contracts/v1/shielded-token.compact   /src/contracts/v1/shielded-token.compact
COPY --from=source /src/contracts/v1/unshielded-token.compact /src/contracts/v1/unshielded-token.compact
COPY --from=source /src/contracts/v1/receiver.compact         /src/contracts/v1/receiver.compact
COPY --from=source /src/contracts/v1/managed                  /committed/managed
WORKDIR /src

# THE BYTE-EXACT REBUILD, into an EMPTY tree: a compiler that skipped work because its output
# was already present would leave the committed files untouched and the diff would pass while
# having verified nothing.
#
# HOME and XDG_CACHE_HOME are redirected because the default HOME is /root, and an SRS cache
# written there would be baked into a layer nothing reads.
#
# All THREE v1 contracts, not only the two the deploy runner instantiates: the faucet site
# serves `receiver`'s proving keys to the browser for a contract-recipient mint, so its keys
# are as load-bearing as the issuers'. Measured on this host, 2026-09-08: 17 s + 8 s + 88 s.
RUN set -eux; \
    for p in shielded unshielded receiver; do \
      case "${p}" in \
        shielded)   src=contracts/v1/shielded-token.compact ;; \
        unshielded) src=contracts/v1/unshielded-token.compact ;; \
        receiver)   src=contracts/v1/receiver.compact ;; \
      esac; \
      echo "compiling ${src} -> contracts/v1/managed/${p}/"; \
      HOME=/tmp XDG_CACHE_HOME=/tmp/zk-cache \
        /opt/compactc/compactc "${src}" "contracts/v1/managed/${p}/"; \
      test -d "contracts/v1/managed/${p}/contract"; \
      test -d "contracts/v1/managed/${p}/keys"; \
      test -d "contracts/v1/managed/${p}/zkir"; \
    done; \
    # Circuit counts, because "the compile produced SOMETHING" and "the compile produced these
    # contracts" are different claims and only the second one is worth anything. The two issuers
    # expose name/symbol/decimals/tokenColor/mint; the receiver exposes nine.
    for p in shielded unshielded; do \
      n="$(ls -1 "contracts/v1/managed/${p}/keys"/*.verifier | wc -l)"; \
      test "${n}" -eq 5 || { echo "FAIL: ${p}: expected 5 circuits, compiled ${n}" >&2; ls -1 "contracts/v1/managed/${p}/keys" >&2; exit 1; }; \
      test -s "contracts/v1/managed/${p}/keys/mint.prover"; \
      test -s "contracts/v1/managed/${p}/keys/mint.verifier"; \
    done; \
    n="$(ls -1 contracts/v1/managed/receiver/keys/*.verifier | wc -l)"; \
    test "${n}" -eq 9 || { echo "FAIL: receiver: expected 9 circuits, compiled ${n}" >&2; ls -1 contracts/v1/managed/receiver/keys >&2; exit 1; }; \
    # THE ASSERTION THIS WHOLE STAGE EXISTS FOR. `compactc` is deterministic, so this is exact,
    # not heuristic: a difference means the source was edited, the compiler version differs, or
    # the committed artifacts are not what this source produces — and in every one of those
    # cases this stack would deploy contracts whose on-chain verifier keys are not the ones the
    # registry claims, and the faucet site would serve proving keys that cannot satisfy them.
    if ! diff -r contracts/v1/managed /committed/managed; then \
      echo "FAIL: recompiling contracts/v1/*.compact with compactc ${COMPACT_VERSION} did not reproduce the committed contracts/v1/managed/." >&2; \
      echo "      Do not weaken this check: the registry records the artifact digest as provenance." >&2; \
      exit 1; \
    fi; \
    mkdir -p /verified; \
    printf 'compactc %s reproduced contracts/v1/managed byte-for-byte (5+5+9 circuits)\n' "${COMPACT_VERSION}" > /verified/COMPACT-OK; \
    cat /verified/COMPACT-OK

# ── stage 2: install the four dependency sets and build the static site ──────
FROM ${NODE_BUILD_BASE} AS build

WORKDIR /src
COPY --from=source /src /src
# THE GATE, CARRIED FORWARD AS A FILE. Without this COPY the `compact` stage is not in this
# target's dependency graph and BuildKit would simply never run it — the byte-exactness proof
# would become a stage nothing asks for.
COPY --from=compact /verified/COMPACT-OK /verified/COMPACT-OK

# ALL FOUR INSTALLS, in upstream's own order and for upstream's own reason (frontend/README.md):
# the separate lockfiles are what stop the WASM-backed Midnight 1.x and 2.x dependency graphs
# from being deduplicated into one incompatible runtime. Installing fewer would make this build
# pass while shipping a site whose v1 lane cannot prove anything.
#
# `npm ci` (frozen by construction — it installs the lockfile or fails), no `--ignore-scripts`
# for the frontend sets because vite/rollup ship optional platform binaries whose install is a
# script. The ROOT install is the one the deploy runtime ships, and it takes `--ignore-scripts`
# exactly as upstream's own local-deployment command does.
RUN npm ci --ignore-scripts
RUN npm --prefix frontend ci
RUN npm --prefix frontend/protocols/v1 ci
RUN npm --prefix frontend/protocols/v2 ci

# `npm run build` at the root is `tsc -b`: it produces packages/registry/dist, which is BOTH
# what `npm run check` validates the tracked registries with and what the frontend imports
# through its `file:../packages/registry` dependency. The deploy runtime needs it too — the
# validator this stack runs against its OWN registry is that same compiled package.
RUN npm run build
RUN npm run check

# The site. `npm --prefix frontend run build` is upstream's composite: it re-runs the root
# check, verifies the bundled client-artifact identities against Git (which is why stage
# `source` fetched the two extra commits), typechecks, then `vite build`.
RUN npm --prefix frontend run build

# WHAT THE BUILT SITE MUST AND MUST NOT CONTAIN. Upstream's own release gate, transcribed from
# frontend/README.md's verified-release procedure — the parts that are meaningful for a LOCAL
# faucet — because a `dist` that quietly lost one of these serves a page that loads and then
# cannot mint.
RUN set -eux; \
    cd /src/frontend/dist; \
    test -f index.html; \
    test -f 404.html; \
    test -f favicon.svg; \
    # The local registry must NEVER be baked in: it is per-stack, it is published by this
    # stack's own one-shot onto a volume, and a stale copy inside the image would be served in
    # preference to nothing at all — which is worse than a 404 the SPA already understands.
    test ! -e metadata.undeployed.json \
      || { echo "FAIL: dist carries a baked metadata.undeployed.json" >&2; exit 1; }; \
    # The three PUBLIC registries are copied in by vite and are harmless — the site can show
    # Preview/Preprod/Stagenet read-only. Asserted present so a change in that behaviour is
    # noticed rather than discovered by a user.
    for n in preview preprod stagenet; do test -s "metadata.${n}.json"; done; \
    # `_headers` survives into dist unchanged (Cloudflare Pages reads it there). nginx does not
    # read it — images/issuer/nginx.conf transcribes it — so this is the second half of the
    # content pin in stage `source`: the policy the config describes is the policy that shipped.
    cmp /src/frontend/public/_headers _headers; \
    # The v1 proving artifacts the browser fetches for a mint, and the receiver keys a
    # contract-recipient mint needs. `response.ok` is all midnight-js checks, so a missing key
    # served as the SPA shell would be handed to the prover as a proving key.
    for p in shielded unshielded; do \
      test -s "contract/v1/${p}/keys/mint.prover"; \
      test -s "contract/v1/${p}/keys/mint.verifier"; \
      n="$(ls -1 "contract/v1/${p}/keys"/*.verifier | wc -l)"; \
      test "${n}" -eq 5 || { echo "FAIL: dist serves ${n} v1 ${p} verifier keys, expected 5" >&2; exit 1; }; \
    done; \
    test -s contract/v1/receiver/keys/receiveShieldedTokenFromIssuer.prover; \
    test -s contract/v1/receiver/keys/receiveUnshieldedTokenFromIssuer.verifier; \
    # The bundle really carries the undeployed lane: `?network=undeployed` is how this stack's
    # faucet is opened, and a build that dropped the key would show four networks and not this
    # one. A property name in a union type, emitted verbatim by esbuild.
    grep -rqF 'undeployed' assets \
      || { echo "FAIL: the built bundle has no 'undeployed' network lane" >&2; exit 1; }; \
    echo "OK: frontend/dist carries the site, both v1 issuers' keys, the receiver's keys and no local registry"

# ── runtime target: the deploy one-shot, the registrar and the funding CLI ────
# The node runtime with the pinned tree, its ROOT node_modules, its .git — and nothing from the
# frontend. This target never serves a page.
FROM ${NODE_RUNTIME_BASE} AS runtime

# ── the three OS packages this image needs, and exactly why ──────────────────
#   git                 the deploy runner's provenance checks (see this file's header). Without
#                       it `npm run deploy:v1` fails before it opens a socket.
#   postgresql-client   `entrypoint-registrar.sh` runs the kernel's own prescribed
#                       `UPDATE known_tokens … WHERE name = <NAME>` with psql, for the same
#                       reason images/shielded-night carries it (00015 / issues/00012): the
#                       name is UNIQUE and POST /v1/known-tokens checks the NAME before the
#                       colour, so on a kernel that seeds the six Preprod rows the POST can
#                       never register the real colour under its own name. Debian trixie ⇒
#                       psql 17, the same major as this stack's postgres:17-alpine.
#   curl                EVERY readiness probe and every kernel API call in these entrypoints.
#                       The bun-based images in this repository probe with `bun -e fetch`
#                       because their base ships no curl and installing one for a probe would
#                       grow the image for nothing; here the base is Debian, `node -e` would
#                       pay Node's startup cost on every one of a hundred poll iterations, and
#                       an operator debugging a one-shot by hand wants curl anyway. NOT
#                       PRESENT IN THE SLIM BASE — measured: `node:24.15.0-trixie-slim` has no
#                       curl at all, and the first bring-up of this profile spent its whole
#                       node-block wait on `curl: not found` swallowed by `2>/dev/null`.
#   ca-certificates     already present in the node image; named so an audit sees the set.
#
# ASSERTED, not assumed: a base-image change that dropped one would otherwise surface as a
# one-shot failing at bring-up with "command not found" — or, worse, as a bounded wait that
# times out with no clue why, which is exactly what happened before curl was added here.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends git postgresql-client curl ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    command -v git; git --version; \
    command -v psql; psql --version; \
    command -v curl; curl --version | head -1; \
    # `getent` resolves the kernel's hostname in entrypoint-registrar.sh's presence gate. It is
    # in libc-bin and cannot realistically go missing, but the gate's whole job is to
    # distinguish "no kernel here" from "a kernel that is still booting", and a missing getent
    # would silently answer the first for a stack that is fine.
    command -v getent; \
    # `flock` is the genesis-1 facade mutex (00011 Q7), taken by entrypoint-deploy.sh before it
    # touches genesis-1. util-linux is in the Debian base; asserted so a base change cannot
    # silently remove the mutex and turn a contended bring-up into two facades on one seed.
    command -v flock; flock --version

WORKDIR /app
COPY --from=build /src /app
# THE COMMIT, AS A FILE AT A FIXED PATH, in both runtime targets. `scripts/verify-source-pins.sh`
# reads it with `docker run --rm --entrypoint cat <image> /.issuer-commit` and compares it to
# ISSUER_REF and to config/artifact-decisions.json — the same assertion every other
# source-built image in this repository carries. The .git directory below could answer the same
# question, but not with one `cat` and not without a git binary in the asserting shell.
COPY --from=source /.issuer-commit /.issuer-commit

# THE FIRST-PARTY SCRIPTS, and they are deliberately INSIDE /app rather than mounted beside it.
# node resolves a bare specifier by walking up from the IMPORTING FILE, so a script at /mnt/…
# would look in /mnt/node_modules and /node_modules and find nothing; at /app/m1 it finds
# /app/node_modules, and its relative imports of the pinned tree's own primitives
# (../packages/registry/src/*, ../contracts/v1/managed/*) resolve too. Nothing here is a
# transcription of that tree — see PROVENANCE.md.
COPY m1 /app/m1
COPY entrypoint-common.sh /usr/local/lib/issuer/entrypoint-common.sh
# VERSIONED SQL, shipped in the image beside the entrypoint that runs it — not inlined into a
# shell string and not mounted from the host. `psql -f` is then given a path an operator can
# `cat`, diff against the kernel's own comment, and run by hand against a live stack.
COPY sql /usr/local/lib/issuer/sql
COPY entrypoint-deploy.sh entrypoint-registrar.sh entrypoint-fund.sh entrypoint-registry.sh \
     /usr/local/bin/
RUN set -eux; \
    chmod 0755 /usr/local/bin/entrypoint-deploy.sh /usr/local/bin/entrypoint-registrar.sh \
               /usr/local/bin/entrypoint-fund.sh /usr/local/bin/entrypoint-registry.sh; \
    chmod 0644 /usr/local/lib/issuer/entrypoint-common.sh; \
    chmod 0644 /usr/local/lib/issuer/sql/issuer-registry-patch.sql; \
    test -s /usr/local/lib/issuer/sql/issuer-registry-patch.sql; \
    # `issuer-fund` is the name every other profile's provisioning will call. Give it one.
    ln -s /usr/local/bin/entrypoint-fund.sh /usr/local/bin/issuer-fund; \
    # THE REPOSITORY MUST STILL LOOK CLEAN TO THE DEPLOY RUNNER. /app/m1 is ours, not
    # upstream's, so it is excluded LOCALLY (never by editing the tree's own .gitignore, which
    # would make `git diff <pin>` non-empty and refuse every deployment).
    printf '/m1/\n' >> /app/.git/info/exclude; \
    # Root owns /app and these containers run as root, so ownership is never "dubious" — but a
    # future non-root variant would have every git call refuse, and the failure reads as a
    # missing repository rather than a permission policy. One line now, no surprise later.
    git config --global --add safe.directory /app; \
    cd /app; \
    # THE PROVENANCE PRECONDITION, PROVEN AT BUILD TIME rather than discovered at bring-up.
    # These are the exact four checks scripts/lib/deployment-provenance.ts makes before it will
    # submit a deployment; an image that fails them cannot issue a token, and finding that out
    # here costs seconds instead of a stack bring-up.
    for p in contracts/v1/shielded-token.compact contracts/v1/unshielded-token.compact \
             contracts/v1/managed/shielded contracts/v1/managed/unshielded; do \
      git cat-file -e "HEAD:${p}" || { echo "FAIL: HEAD does not contain ${p}" >&2; exit 1; }; \
    done; \
    changed="$(git diff --name-only HEAD -- contracts/v1/shielded-token.compact contracts/v1/unshielded-token.compact contracts/v1/managed/shielded contracts/v1/managed/unshielded)"; \
    untracked="$(git ls-files --others --exclude-standard -- contracts/v1)"; \
    ignored="$(git ls-files --others --ignored --exclude-standard -- contracts/v1)"; \
    if [ -n "${changed}${untracked}${ignored}" ]; then \
      echo "FAIL: the v1 source/artifact paths do not match the pinned commit; the deploy runner would refuse" >&2; \
      printf '%s\n' "${changed}" "${untracked}" "${ignored}" >&2; exit 1; \
    fi; \
    echo "OK: /app is a clean git checkout of $(git rev-parse HEAD) and the v1 provenance paths match it"; \
    # The registry directory and the resume-journal directory. compose mounts a named volume
    # over each; creating them here means a `docker run` without the volumes fails on the
    # deploy rather than on a missing directory three steps later.
    mkdir -p /srv/issuer-registry /app/.local; \
    # The deploy runner writes the seed file itself, into a tmpfs the entrypoint creates. The
    # directory exists so a read-only-rootfs run fails on the mount rather than on a mkdir.
    mkdir -p /run/issuer

# No CMD: compose names the entrypoint per service, exactly as images/offerfiles-kernel and
# images/shielded-night do for their several roles.
ENTRYPOINT ["/usr/local/bin/entrypoint-deploy.sh"]

# ── runtime target 2: nginx serving the faucet site and the stack's registry ──
FROM ${NGINX_BASE} AS faucet

COPY --from=build  /src/frontend/dist /usr/share/nginx/html
COPY --from=source /.issuer-commit /.issuer-commit
COPY PROVENANCE.md /usr/share/licenses/issuer/PROVENANCE.md

COPY nginx.conf /etc/nginx/conf.d/default.conf
RUN set -eux; \
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
    # The registry is served from a volume this image does not carry. The MOUNT POINT exists so
    # that a run without the volume answers 404 (which the SPA understands as "unavailable")
    # instead of failing nginx's own startup on a missing root.
    mkdir -p /srv/issuer-registry; \
    nginx -t

EXPOSE 10500
CMD ["nginx", "-g", "daemon off;"]
