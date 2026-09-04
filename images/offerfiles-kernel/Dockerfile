# offerfiles-kernel — the ZSwap offer-files kernel (1.x line, `main`) running in
# EXTERNAL-STACK mode against this compose stack's node/indexer/proof-server, the shared
# PostgreSQL, and the local Celestia devnet.
#
# ONE IMAGE, THREE CONTAINERS. The contract-deploy one-shot, the sync node (:9999) and the
# balancing batcher (:3334) all run this image with their own entrypoint:
#
#   entrypoint-deploy.sh       one-shot — deploy the contract ONCE per stack, publish its
#                              address and the minted dev-token colours on a shared volume
#   entrypoint-kernel.sh       exec bun run packages/node/main.dev.ts      (:9999)
#   entrypoint-batcher.sh      exec bun run packages/batcher/batcher.dev.ts (:3334)
#   entrypoint-token-names.sh  one-shot — finish the mint by naming the three colours through
#                              the kernel's own POST /v1/known-tokens, which the upstream mint
#                              script tries to do against a pre-/v1 path and silently fails at
#
# SINCE 00011 PR C IT IS ONE IMAGE, FIVE CONTAINERS: the `poster` profile adds two more, and
# they are the kernel repository's own processes rather than anything invented here —
#
#   entrypoint-poster-provision.sh  one-shot — four large NIGHT UTXOs from genesis to the
#                                   poster's dedicated wallet, under the genesis-1 flock
#   entrypoint-offer-poster.sh      THE LOOP — `deploy/scripts/offer-poster.ts`, which mints
#                                   one faucet coin a tick and posts one sponsored offer
#                                   spending exactly that coin
#
# AND SINCE 00014 IT IS ONE IMAGE, SIX CONTAINERS: the `prices` profile adds the kernel
# repository's own reference-price refresher —
#
#   entrypoint-price-feed.sh        THE OTHER LOOP — `packages/price-feed/price-feed.dev.ts`,
#                                   one CoinGecko `simple/price` call a day into
#                                   `asset_prices`. The only process here that talks to the
#                                   public internet, and the only one that holds a secret;
#                                   it waits on the DATABASE and on nothing else
#
# WHY NO ORCHESTRATOR. The repository's own `bun run dev` is `bunx orchestrator start`, whose
# launchMidnight()/launchCelestia() open with `stopProcessAtPort [9944, 8088, 6300, 26657,
# 26658, 3334]` — pointed at a live stack it FIRST KILLS the listeners it was meant to use.
# It also re-runs the contract deploy on every start, and `midnight-contract:deploy` is
# literally `midnight-contract:clean && deploy.ts` where clean is
# `rm -f contract-offer-files.<network>.json`. So an orchestrated recreate mints a NEW
# contract and resets the order book's identity. Each entrypoint here is a single `exec`d
# process instead, so the container's PID 1 is the real workload and compose's SIGTERM
# reaches it.
#
# `*.dev.ts` and NOT `*.mainnet.ts`: "dev" names the target NETWORK, not the maturity of the
# code. The mainnet variants resolve mainnet endpoints and hard-gate on
# CELESTIA_NETWORK=mainnet; this stack is an `undeployed` devnet.
#
# THE CONTRACT IS COMPILED AT BUILD TIME. `packages/contracts-midnight/contract-offer-files/
# src/managed/` is gitignored in the kernel repository, so it exists only because of stage 2
# below — the deploy one-shot, `readMidnightContract()` and the mint script all read it at
# runtime. Compiling it here is also what lets the frontend image reuse ONE compiler for the
# whole stack instead of pinning a second one.

# ── base images: index digests, not tags ─────────────────────────────────────
# Both are good official multiarch indexes (linux/amd64 + linux/arm64 confirmed
# 2026-09-01 with `docker buildx imagetools inspect`), so nothing here needs a `platform:`
# pin and both architectures build native. A tag is not an identity: `oven/bun:1.3.11` can
# be repointed at different bytes without one character of this repository changing.
#
# debian:trixie-slim is the SAME digest images/celestia pins, deliberately — one fewer
# external identity in the stack, and one already vetted.
ARG DEBIAN_BASE=debian:trixie-slim@sha256:f6e2cfac5cf956ea044b4bd75e6397b4372ad88fe00908045e9a0d21712ae3ba
# bun is PINNED to 1.3.11 for a measured reason, not for tidiness: bun 1.3.14 fails
# `midnight-contract:deploy` with `require() async module ".../graphql/index.mjs" is
# unsupported` (graphql-tag's UMD build require()ing the ESM graphql 17), and that deploy is
# one of this image's three entrypoints. Both the 1.x deploy prototype and the 2.x sibling
# stack landed on the same pin from the same failure. Bump only with a full bring-up as the
# gate.
ARG BUN_BASE=oven/bun:1.3.11@sha256:0733e50325078969732ebe3b15ce4c4be5082f18c4ac1a0f0ca4839c2e4e42a7

ARG KERNEL_REPO=https://github.com/effectstream/zswap-offerfiles-kernel.git
ARG KERNEL_REF=c293ebd57937c0065663b08b2c244438be8989a5
ARG COMPACT_VERSION=0.30.0

# ── stage 1: fetch the kernel source at a FULL commit SHA ────────────────────
# A remote fetch, not a local context, so `git clone <this repo> && ./up.sh --with offerfiles`
# works with nothing else checked out. `--depth 1 origin <sha>` needs the full 40-hex commit;
# an abbreviated sha or a branch name is refused by git itself, which is the cheapest possible
# enforcement of the repository's pinning rule.
FROM ${DEBIAN_BASE} AS source

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

ARG KERNEL_REPO
ARG KERNEL_REF

WORKDIR /src
RUN set -eux; \
    case "${KERNEL_REF}" in \
      ????????????????????????????????????????) : ;; \
      *) echo "FAIL: KERNEL_REF must be a full 40-character commit SHA, got '${KERNEL_REF}'" >&2; exit 1 ;; \
    esac; \
    git init -q .; \
    git remote add origin "${KERNEL_REPO}"; \
    git fetch -q --depth 1 origin "${KERNEL_REF}"; \
    git checkout -q FETCH_HEAD; \
    git rev-parse HEAD > /kernel-commit; \
    test "$(cat /kernel-commit)" = "${KERNEL_REF}"; \
    rm -rf .git

# ── stage 2: compile the Compact contract with a PINNED compactc ─────────────
# WHICH COMPILER, AND WHY THIS ONE (00005 P2 finding, 2026-09-01).
#
# The contract package declares `compact compile +0.30.0 src/offer-files.compact
# src/managed/`, i.e. the toolchain manager is asked for exactly 0.30.0. Q9 in the plan's
# questions file recorded that no FINAL 0.30.0 compactc release exists — but that was
# enumerated against `LFDT-Minokawa/compact`, which is a DIFFERENT repository (id
# 1115336329) from `midnightntwrk/compact` (id 967499978), the one whose `compact-installer.sh`
# the toolchain manager itself is distributed from and therefore the one `compact update
# 0.30.0` resolves against. midnightntwrk/compact DOES publish a final `compactc-v0.30.0`
# (release 298133014, 2026-03-17, prerelease=false) with both Linux musl triples.
#
# So this stage fetches that release asset directly and verifies its SHA-256, exactly the way
# the 2.x sibling pins its own compiler — rather than running the version manager, whose
# resolution is a network lookup that cannot be pinned. Same bytes, one fewer moving part.
#
# `compactc <in> <out>` is what `compact compile +V <in> <out>` dispatches to; the manager
# adds nothing this build needs. The bundled wrapper resolves its siblings (notably `zkir`)
# from `dirname $0`, so the archive is unpacked whole and nothing is symlinked out of it.
FROM ${DEBIAN_BASE} AS compact

ARG COMPACT_VERSION
ARG TARGETARCH
ARG COMPACT_REPO=midnightntwrk/compact
# SHA-256 of each release asset, from the GitHub release API's own `digest` field
# (2026-09-01). These, not the URL, are the compiler's identity: a release asset can be
# re-uploaded under the same name.
ARG COMPACT_SHA256_AMD64=06641b55befd35384ece539f7b12b65cb2cf6fb49996d27ef17a02fcacad4d2d
ARG COMPACT_SHA256_ARM64=e4f36268ee652f1415d253d9fabd64a92b5eb0dc7cf28f40fa68c2445c7b3341

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
    # A darwin asset in a Linux build stage is the exact mistake the matrix's
    # forbiddenAssetSubstrings list exists to prevent; assert it cannot happen here either.
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
    # The zkir backend ships beside compactc and is invoked as a sibling. An asset without it
    # compiles nothing, and would fail much later with a missing-executable error.
    test -x /opt/compactc/zkir || { echo "FAIL: the asset lacks the default zkir backend" >&2; exit 1; }; \
    # The pin says 0.30.0; make the BINARY say so too. A release asset renamed or re-uploaded
    # under the wrong version would otherwise be caught by nothing until a verifier key was
    # rejected at runtime, which is a very expensive way to learn it.
    ver="$(/opt/compactc/compactc --version 2>&1 || true)"; \
    echo "compactc reports: ${ver}"; \
    case "${ver}" in \
      *"${COMPACT_VERSION}"*) : ;; \
      *) echo "FAIL: compactc does not report version ${COMPACT_VERSION}: ${ver}" >&2; exit 1 ;; \
    esac

# Only the contract package, so an edit anywhere else in the kernel tree does not invalidate
# this layer. Key generation is the expensive part of the whole build.
COPY --from=source /src/packages/contracts-midnight/contract-offer-files /contract

# Proving-key generation downloads the universal SRS from srs.midnight.network into
# $XDG_CACHE_HOME — a build-time network fetch, like the git fetch in stage 1. HOME is
# redirected too: the default HOME here is /root, and a cache written there would be baked
# into a layer nothing reads.
RUN set -eux; \
    cd /contract; \
    HOME=/tmp XDG_CACHE_HOME=/tmp/zk-cache /opt/compactc/compactc src/offer-files.compact src/managed/; \
    test -d /contract/src/managed/contract; \
    test -d /contract/src/managed/keys; \
    test -d /contract/src/managed/zkir

# ── stage 3: the runtime image ───────────────────────────────────────────────
FROM ${BUN_BASE}

WORKDIR /app
COPY --from=source /src /app
# Which commit this image is, readable from a running container — so "what is in here?" does
# not depend on remembering which tag it was built as.
COPY --from=source /kernel-commit /app/.kernel-commit
COPY --from=compact /contract/src/managed /app/packages/contracts-midnight/contract-offer-files/src/managed

# Frozen: the lockfile at the pinned commit IS the tested dependency set. `--frozen-lockfile`
# turns "a transitive dependency published a new version" from a silent difference into a
# build failure.
RUN bun install --frozen-lockfile

# ── entrypoints, last ────────────────────────────────────────────────────────
# Copied after the install and the contract so that editing one costs a second, not the
# ~20-minute key generation.
COPY wait-for.sh           /usr/local/bin/wait-for.sh
COPY entrypoint-common.sh  /usr/local/lib/offerfiles/entrypoint-common.sh
# A PROBE, not an entrypoint: `verify-kernel.sh` runs it with `docker compose exec kernel bun
# run …` to read the faucet allotment out of THIS image's own pinned tree and to make the two
# preset faucet colours nameable/priceable. It lives OUTSIDE /app on purpose — the kernel tree
# stays exactly the pinned commit — and imports what it needs by absolute path.
COPY faucet-probe.ts       /usr/local/lib/offerfiles/faucet-probe.ts
# The poster's funding script, OUTSIDE /app for the same reason faucet-probe.ts is (00011
# Q12). Unlike the probe it imports third-party packages by bare specifier, and bun resolves
# those by walking up from the IMPORTING FILE — so entrypoint-poster-provision.sh installs it
# into /app/.m1/ at RUNTIME, where /app/node_modules is on the way up. The image's /app tree
# stays exactly the pinned commit plus its compiled Compact artifacts.
COPY poster-provision.ts   /usr/local/lib/offerfiles/poster-provision.ts
COPY entrypoint-deploy.sh entrypoint-kernel.sh entrypoint-batcher.sh \
     entrypoint-token-names.sh entrypoint-poster-provision.sh \
     entrypoint-offer-poster.sh entrypoint-price-feed.sh /usr/local/bin/
RUN chmod 0755 /usr/local/bin/wait-for.sh \
               /usr/local/bin/entrypoint-deploy.sh \
               /usr/local/bin/entrypoint-kernel.sh \
               /usr/local/bin/entrypoint-batcher.sh \
               /usr/local/bin/entrypoint-token-names.sh \
               /usr/local/bin/entrypoint-poster-provision.sh \
               /usr/local/bin/entrypoint-offer-poster.sh \
               /usr/local/bin/entrypoint-price-feed.sh \
 && chmod 0644 /usr/local/lib/offerfiles/entrypoint-common.sh \
               /usr/local/lib/offerfiles/faucet-probe.ts \
               /usr/local/lib/offerfiles/poster-provision.ts

# The genesis-1 facade mutex (00011 Q7) is a `flock`, and three one-shots across two compose
# fragments depend on it existing. util-linux is in this base image today (2.41, measured);
# asserting it here turns a future base-image change from a SILENT loss of the mutex — two
# wallet facades on one seed, which presents as an unrelated service going quiet hours later
# — into a build failure.
RUN command -v flock >/dev/null \
 || { echo "FAIL: flock (util-linux) is not in this base image; the genesis-1 facade mutex needs it" >&2; exit 1; }

# :9999 sync-node API, :3334 batcher. Which one a container serves is decided by the
# entrypoint compose selects, never by this image.
EXPOSE 9999 3334

# No default command. Every service in compose/offerfiles.yml names its entrypoint
# explicitly, so a service that forgot to must REFUSE rather than silently become a kernel.
CMD ["/bin/sh", "-c", "echo 'this image has no default command — select one of /usr/local/bin/entrypoint-{deploy,kernel,batcher,token-names,poster-provision,offer-poster,price-feed}.sh' >&2; exit 64"]
