# offerfiles-kernel — the ZSwap offer-files kernel (1.x line, `main`) running in
# EXTERNAL-STACK mode against this compose stack's node/indexer/proof-server, the shared
# PostgreSQL, and the local Celestia devnet.
#
# ONE IMAGE, SIX CONTAINERS. Every one of them is this image with a different entrypoint:
#
#   entrypoint-kernel.sh            exec bun run packages/node/main.dev.ts      (:9999)
#   entrypoint-batcher.sh           exec bun run packages/batcher/batcher.dev.ts (:3334)
#   entrypoint-night-provision.sh   one-shot — four large NIGHT UTXOs from genesis to ONE
#                                   named wallet, under the genesis-1 flock. Used by
#                                   `poster-provision` (profile `poster`) and `maker-provision`
#                                   (profile `solver`), which differ only in environment
#   entrypoint-offer-poster.sh      THE LOOP — `deploy/scripts/offer-poster.ts`, which posts one
#                                   sponsored offer a tick spending exactly one PREFUNDED coin
#                                   (profile `poster`)
#   entrypoint-price-feed.sh        THE OTHER LOOP — `packages/price-feed/price-feed.dev.ts`,
#                                   one CoinGecko `simple/price` call a day into `asset_prices`.
#                                   The only process here that talks to the public internet, and
#                                   the only one that holds a secret; it waits on the DATABASE
#                                   and on nothing else (profile `prices`)
#
# and images/cow-solver is `FROM` this image plus four more entrypoints (solver, its monitor,
# solver-provision, maker-offer), so the whole solver lane carries this same commit.
#
# ─── WHAT KERNEL #69 REMOVED FROM THIS IMAGE (00020 PR C) ────────────────────
# Up to `KERNEL_REF=a608fa6…` this image had a THIRD stage that compiled the kernel's own
# Compact contract (`packages/contracts-midnight/contract-offer-files`, pragma
# `compact compile +0.30.0`) with a sha256-pinned compactc 0.30.0, generated its proving keys —
# about twenty minutes of build — and copied `src/managed/` into the runtime layer, because the
# deploy one-shot, `readMidnightContract()` and the mint script all read it at run time.
#
# **AT `e3b9388…` THERE IS NOTHING LEFT TO COMPILE.** Kernel #69 deleted that whole package
# along with `deploy.ts`, `mint-test-tokens.ts`, `register-known-tokens.ts`,
# `packages/node/zk-assets.ts` (so `GET /keys/*` and `GET /zkir/*` are gone) and
# `deploy/scripts/lib/faucet-mint.ts`; `entrypoint-common.sh` upstream lost
# `adopt_contract_address()` and `CONTRACT_SHARE_DIR`; and `GET /v1/midnight/config` no longer
# carries a `contractAddress`. So this image has NO Compact stage, NO `COMPACT_VERSION` ARG and
# NO `compactc` of any version — and the ~20-minute key generation is gone with it.
#
# There is no `entrypoint-deploy.sh` and no `entrypoint-token-names.sh` here any more either:
# the stack's tokens come from the `issuer` profile (`images/issuer`, built from
# `effectstream/mint-test-tokens` at `ISSUER_REF`), which deploys six token contracts once per
# chain, publishes their registry, and teaches this kernel their colours through the
# `issuer-registrar` one-shot. See docs/COMPONENTS.md and docs/OPERATIONS.md.
#
# ─── WHY NO ORCHESTRATOR ─────────────────────────────────────────────────────
# The repository's own `bun run dev` is `bunx orchestrator start`, whose
# launchMidnight()/launchCelestia() open with `stopProcessAtPort [9944, 8088, 6300, 26657,
# 26658, 3334]` — pointed at a live stack it FIRST KILLS the listeners it was meant to use. It
# is also the ONLY caller of `packages/database/import-token-registry.ts`, the canonical-registry
# importer #69 added, which fetches `https://mint-test-tokens.pages.dev/metadata.<network>.json`
# — a public network's registry that has nothing to do with an `undeployed` chain. Each
# entrypoint here is a single `exec`d process instead, so the container's PID 1 is the real
# workload and compose's SIGTERM reaches it, and the public import is never attempted.
#
# `*.dev.ts` and NOT `*.mainnet.ts`: "dev" names the target NETWORK, not the maturity of the
# code. The mainnet variants resolve mainnet endpoints and hard-gate on
# CELESTIA_NETWORK=mainnet; this stack is an `undeployed` devnet.

# ── base images: index digests, not tags ─────────────────────────────────────
# Both are good official multiarch indexes (linux/amd64 + linux/arm64 confirmed
# 2026-09-01 with `docker buildx imagetools inspect`), so nothing here needs a `platform:`
# pin and both architectures build native. A tag is not an identity: `oven/bun:1.3.11` can
# be repointed at different bytes without one character of this repository changing.
#
# debian:trixie-slim is the SAME digest images/celestia pins, deliberately — one fewer
# external identity in the stack, and one already vetted.
ARG DEBIAN_BASE=debian:trixie-slim@sha256:f6e2cfac5cf956ea044b4bd75e6397b4372ad88fe00908045e9a0d21712ae3ba
# bun is PINNED to 1.3.11 because that is the runtime the pinned kernel commit is developed and
# tested on, and the version its own deployment image pins. Upstream's stated reason has
# narrowed with #69 (the `midnight-contract:deploy` entrypoint that bun 1.3.14 broke through
# graphql-tag's UMD/ESM interop no longer exists), but the pin is still the tested runtime and
# upstream still says "keep runtime testing on this pinned image". Bump only with a full
# bring-up as the gate.
ARG BUN_BASE=oven/bun:1.3.11@sha256:0733e50325078969732ebe3b15ce4c4be5082f18c4ac1a0f0ca4839c2e4e42a7

ARG KERNEL_REPO=https://github.com/effectstream/zswap-offerfiles-kernel.git
ARG KERNEL_REF=e3b9388d11dfe1a6c5554a4c8699250fe595e4ce

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

# ── THE FAUCET CONTRACT IS GONE — ASSERT IT, do not merely stop compiling it ──
# This stack ran a Compact stage here for four pins, and the failure mode of a re-pin that
# moved BACKWARDS (or of a KERNEL_REF that never left the faucet line) would be a runtime image
# whose kernel expects `packages/contracts-midnight/contract-offer-files/src/managed/` and finds
# nothing — surfacing much later as `readMidnightContract()` throwing inside the sync node. So
# the removal is a BUILD-TIME assertion in both directions:
#
#   * the deleted package must be absent — if it is back, this image needs its Compact stage
#     back too, and silently shipping without one would be the worst of the three outcomes;
#   * the retired entrypoint scripts must be absent from the pinned tree as well, because they
#     are what the deleted package existed for.
#
# `test ! -e` and not a grep: the question is about the tree, and the tree answers it exactly.
RUN set -eux; \
    for gone in \
      packages/contracts-midnight/contract-offer-files \
      packages/contracts-midnight/mint-test-tokens.ts \
      packages/contracts-midnight/register-known-tokens.ts \
      packages/node/zk-assets.ts \
      deploy/scripts/lib/faucet-mint.ts \
      deploy/images/kernel/entrypoint-deploy.sh \
      deploy/images/kernel/entrypoint-mint-test-tokens.sh ; do \
      if [ -e "/src/${gone}" ]; then \
        echo "FAIL: /src/${gone} EXISTS at KERNEL_REF=${KERNEL_REF}." >&2; \
        echo "      This image has no Compact stage since kernel #69 removed the local faucet" >&2; \
        echo "      contract. A KERNEL_REF that still ships it needs that stage back — see the" >&2; \
        echo "      header of this Dockerfile and git history for the removed stage." >&2; \
        exit 1; \
      fi; \
    done; \
    # And the pieces this stack DOES still run must be there. A pin that deleted these would
    # otherwise fail inside a container, three services away from the cause.
    for needed in \
      packages/node/main.dev.ts \
      packages/batcher/batcher.dev.ts \
      packages/price-feed/price-feed.dev.ts \
      deploy/scripts/offer-poster.ts \
      deploy/scripts/provision-solver-fees.ts \
      deploy/scripts/post-maker-offer.ts \
      deploy/scripts/e2e.ts \
      packages/database/migrations/000-init.sql ; do \
      test -e "/src/${needed}" || { echo "FAIL: /src/${needed} is MISSING at KERNEL_REF=${KERNEL_REF}" >&2; exit 1; }; \
    done; \
    echo "OK: the pinned tree is the post-#69 external-inventory kernel"

# ── stage 2: the runtime image ───────────────────────────────────────────────
FROM ${BUN_BASE}

WORKDIR /app
COPY --from=source /src /app
# Which commit this image is, readable from a running container — so "what is in here?" does
# not depend on remembering which tag it was built as.
COPY --from=source /kernel-commit /app/.kernel-commit

# Frozen: the lockfile at the pinned commit IS the tested dependency set. `--frozen-lockfile`
# turns "a transitive dependency published a new version" from a silent difference into a
# build failure.
RUN bun install --frozen-lockfile

# ── entrypoints, last ────────────────────────────────────────────────────────
# Copied after the install so that editing one costs a second rather than a re-install.
COPY wait-for.sh           /usr/local/bin/wait-for.sh
COPY entrypoint-common.sh  /usr/local/lib/offerfiles/entrypoint-common.sh
# THE TOKEN HANDOFF (00020 PR C). Sourced by every entrypoint that needs a token id, it reads
# the `tokens.env` file the ISSUER publishes on the shared `issuer-tokens` volume. It contains
# no registry parser of its own on purpose: `images/issuer/m1/registry.ts` is the ONE reader of
# `metadata.undeployed.json` in this stack, and this file consumes its output.
COPY registry-env.sh      /usr/local/lib/offerfiles/registry-env.sh
# The NIGHT funding script, OUTSIDE /app for the same reason the retired faucet probe was
# (00011 Q12). Unlike a probe it imports third-party packages by bare specifier, and bun
# resolves those by walking up from the IMPORTING FILE — so entrypoint-night-provision.sh
# installs it into /app/.m1/ at RUNTIME, where /app/node_modules is on the way up. The image's
# /app tree stays exactly the pinned commit.
COPY night-provision.ts    /usr/local/lib/offerfiles/night-provision.ts
COPY entrypoint-kernel.sh entrypoint-batcher.sh \
     entrypoint-night-provision.sh \
     entrypoint-offer-poster.sh entrypoint-price-feed.sh /usr/local/bin/
RUN chmod 0755 /usr/local/bin/wait-for.sh \
               /usr/local/bin/entrypoint-kernel.sh \
               /usr/local/bin/entrypoint-batcher.sh \
               /usr/local/bin/entrypoint-night-provision.sh \
               /usr/local/bin/entrypoint-offer-poster.sh \
               /usr/local/bin/entrypoint-price-feed.sh \
 && chmod 0644 /usr/local/lib/offerfiles/entrypoint-common.sh \
               /usr/local/lib/offerfiles/registry-env.sh \
               /usr/local/lib/offerfiles/night-provision.ts

# The genesis-1 facade mutex (00011 Q7) is a `flock`, and one-shots across three compose
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
CMD ["/bin/sh", "-c", "echo 'this image has no default command — select one of /usr/local/bin/entrypoint-{kernel,batcher,night-provision,offer-poster,price-feed}.sh' >&2; exit 64"]
