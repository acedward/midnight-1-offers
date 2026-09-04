# cow-solver — the COW posted-price solver in EXECUTION mode, overlaid onto the kernel image.
#
# Source: https://github.com/effectstream/zswap-offerfiles-kernel at the exact SHA SOLVER_REF
# below. No solver source is copied into this repository; a clean clone fetches that commit
# itself.
#
# ── SOLVER_REF IS NOW KERNEL_REF (00011 PR A), AND THE OVERLAY IS ON ITS WAY OUT ──────────
#
# This image used to pin kernel PR #52 (`c37bfa68`), a branch that was a DESCENDANT of the
# kernel pin of the day. Since kernel PR #48 merged the whole solver line into `main` the
# relationship INVERTED: `c37bfa68` became an ANCESTOR of `KERNEL_REF`, 44 commits behind it,
# so overlaying it REVERTED 25 solver files (`packages/solver/src/{run,launch,relay-client,
# swap-job-executor,ladder-source,stock,operation-journal}.ts`, `packages/solver-core/
# {ladder-derivation,offer-files}.ts` and the root `package.json`/`bun.lock`) to their pre-#53
# state while leaving the 7 files added after it in place — a mixed tree whose executable code
# was the PR #52 solver, without #53's capital-free fee sizing and without #58's status
# listener.
#
# At `KERNEL_REF=c293ebd…` that stopped being merely wrong and became a BUILD FAILURE: the
# base image's tree carries workspace packages the old `bun.lock` has never seen
# (`packages/solver-frontend`, the poster's `deploy/scripts/lib/poster-*.ts`), so
# `bun install --frozen-lockfile` below refuses with "lockfile had changes, but lockfile is
# frozen" — measured on this exact pin, 2026-09-03.
#
# So SOLVER_REF now equals KERNEL_REF: the solver IS the kernel commit, which is what the
# kernel repository's own `deploy/compose.yml` runs. The fetch-and-overlay machinery below is
# consequently redundant (it copies the tree the base image already has) and 00011 PR B
# deletes it outright, together with `.solver-commit`, in favour of `FROM kernel-image` plus
# the entrypoints. Keeping the pin move here, in the PR that moves KERNEL_REF, is what keeps
# `./up.sh --all` building at every commit.
#
# ONE IMAGE, THREE CONTAINERS — the same pattern images/offerfiles-kernel uses:
#
#   entrypoint-solver.sh            the long-running solver          (`bun run start.solver.ts`)
#   entrypoint-solver-provision.sh  one-shot — give the solver inventory to trade with
#   entrypoint-maker-offer.sh       one-shot — seed the book with ONE real, settle-able offer
#
# ── WHY IT IS AN OVERLAY AND NOT A SECOND BUILD ─────────────────────────────
# `kernel-image` is a NAMED BUILD CONTEXT that compose wires to `service:kernel`, so this
# stage starts from the image the offerfiles profile just built. Two things follow, and both
# matter:
#
#   * The compiled Compact artifacts (`…/contract-offer-files/src/managed`) are REUSED rather
#     than recompiled. They are gitignored upstream, so they exist only because the kernel
#     image compiled them — and compiling a second, independent copy would put two sets of
#     verifier keys in one stack, which fails at settlement rather than at build.
#   * SOLVER_REF and KERNEL_REF are now the SAME commit, so the tree copied over the base
#     image is the tree that is already there and no file can be reverted by the copy. That
#     is the strongest form of the property this bullet used to argue for ("one commit's
#     contract can never be paired with another's artifacts") — there is only one commit.
#
# The overlay is source-first: the pinned tree's own bun.lock decides the final dependency
# graph, and the kernel image's node_modules survive underneath it purely as an install cache.
# With the two refs equal, that install is a no-op that re-proves the lockfile.

ARG DEBIAN_BASE=debian:trixie-slim@sha256:f6e2cfac5cf956ea044b4bd75e6397b4372ad88fe00908045e9a0d21712ae3ba
ARG SOLVER_REPO=https://github.com/effectstream/zswap-offerfiles-kernel.git
ARG SOLVER_REF=c293ebd57937c0065663b08b2c244438be8989a5

# ── stage 1: fetch the solver branch at a FULL commit SHA ────────────────────
FROM ${DEBIAN_BASE} AS source

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

ARG SOLVER_REPO
ARG SOLVER_REF

WORKDIR /src
RUN set -eux; \
    case "${SOLVER_REF}" in \
      ????????????????????????????????????????) : ;; \
      *) echo "FAIL: SOLVER_REF must be a full 40-character commit SHA, got '${SOLVER_REF}'" >&2; exit 1 ;; \
    esac; \
    git init -q .; \
    git remote add origin "${SOLVER_REPO}"; \
    git fetch -q --depth 1 origin "${SOLVER_REF}"; \
    git checkout -q FETCH_HEAD; \
    git rev-parse HEAD > /solver-commit; \
    test "$(cat /solver-commit)" = "${SOLVER_REF}"; \
    rm -rf .git

# ── stage 2: the runtime image ───────────────────────────────────────────────
FROM kernel-image AS kernel-src
FROM kernel-image

WORKDIR /app

# The branch over the kernel tree, then the kernel's compiled artifacts back on top — that
# ORDER is load-bearing, because the branch checkout has no `managed/` at all (it is
# gitignored upstream) and a COPY of the tree would otherwise leave the directory missing.
COPY --from=source /src /app
COPY --from=kernel-src /app/packages/contracts-midnight/contract-offer-files/src/managed \
     /app/packages/contracts-midnight/contract-offer-files/src/managed
COPY --from=source /solver-commit /app/.solver-commit

# /app/.kernel-commit is INHERITED from the base image and deliberately not overwritten: the
# kernel commit is part of this image's identity too, and scripts/verify-source-pins.sh
# asserts both. A solver built on a different kernel would rebuild maker bytes with
# mismatched artifacts, and that failure surfaces at settlement, not at build.
RUN test -f /app/.kernel-commit \
 && test -f /app/packages/contracts-midnight/contract-offer-files/src/managed/contract/index.js

# Frozen: the branch's lockfile IS the tested dependency set.
RUN bun install --frozen-lockfile

# ── the ledger-v8-only assertion ─────────────────────────────────────────────
# The inverse of the 2.x sibling's ledger-v9 assert, and the same underlying property: TWO
# ledger WASM copies in one process make every value that crosses between them fail
# `instanceof`, which presents as an unrelated type error deep inside a proof. This line is
# 1.x, so v8 must be present and v9 must be absent — the branch's package.json pins
# @midnight-ntwrk/ledger-v8 8.1.0 and carries an `overrides` entry for it, and this is what
# proves the pin actually held through the install.
#
# `find`, not a glob: a hoisted dependency can also live in a NESTED node_modules any depth
# down, and a shell glob would look in exactly one place and report a clean tree.
RUN set -eux; \
    v8="$(find /app/node_modules -type d -name 'ledger-v8' | wc -l)"; \
    test "$v8" -ge 1 \
      || { echo "ERROR: ledger-v8 did not install — this is the 1.x line" >&2; exit 1; }; \
    v9="$(find /app/node_modules -type d -name 'ledger-v9' | wc -l)"; \
    test "$v9" -eq 0 \
      || { echo "ERROR: ledger-v9 is present — two ledger copies in one process" >&2; exit 1; }

# ── entrypoints, last ────────────────────────────────────────────────────────
# Copied after the install so that editing one costs a second rather than a reinstall. They
# source /usr/local/lib/offerfiles/entrypoint-common.sh from the KERNEL image underneath —
# the contract-adoption, Celestia-token and readiness-wait behaviour is identical for these
# containers, and a second copy of it would be a second thing to keep in step.
COPY entrypoint-solver.sh entrypoint-solver-provision.sh entrypoint-maker-offer.sh \
     /usr/local/bin/
RUN chmod 0755 /usr/local/bin/entrypoint-solver.sh \
               /usr/local/bin/entrypoint-solver-provision.sh \
               /usr/local/bin/entrypoint-maker-offer.sh

# No default command: a service that forgot to name its entrypoint must REFUSE rather than
# silently become a solver that trades.
CMD ["/bin/sh", "-c", "echo 'this image has no default command — select one of /usr/local/bin/entrypoint-{solver,solver-provision,maker-offer}.sh' >&2; exit 64"]
