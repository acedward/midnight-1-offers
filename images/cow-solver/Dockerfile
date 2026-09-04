# cow-solver — the COW posted-price solver, its monitor and its two seeding one-shots.
#
# THIS IMAGE IS THE KERNEL IMAGE PLUS FOUR ENTRYPOINTS. It carries no source of its own, no
# second commit identity and no second dependency install: `FROM kernel-image` is the whole
# provenance, and `/app/.kernel-commit` — inherited from the base — is the only commit file
# any container built from here will ever have.
#
# ── WHY THE OVERLAY IS GONE (00011 PR B) ────────────────────────────────────
# Until 00011 this image FETCHED a second commit (`SOLVER_REF`, kernel PR #52 `c37bfa68…`)
# and `COPY`d that tree over the kernel image, then re-ran `bun install --frozen-lockfile`.
# That was sound only while `SOLVER_REF` was a DESCENDANT of `KERNEL_REF`, which is what it
# was when the solver lived on a branch and kernel `main` served neither
# `GET /v1/offers/updates` nor `POST /v1/offers/files`.
#
# Kernel PR #48 merged the whole solver line into `main` and INVERTED that relationship, with
# two consequences:
#
#   1. `c37bfa68` became an ANCESTOR of `KERNEL_REF`, 44 commits behind it. A `COPY` MERGES
#      rather than replaces, so the overlay REVERTED 25 solver files
#      (`packages/solver/src/{run,launch,relay-client,swap-job-executor,ladder-source,stock,
#      operation-journal}.ts`, `packages/solver-core/{ladder-derivation,offer-files}.ts`, the
#      root `package.json` and `bun.lock`, `deploy/scripts/lib/maker-offer.ts`) to their
#      pre-#53/#58 state while LEAVING the 7 files added after it in place
#      (`status-server.ts`, `status.ts`, `fee-sizing.ts`, `status-contract.ts` and their
#      tests). The running solver was a mixed tree whose executable code was the PR #52
#      solver: no capital-free fee sizing, no status listener, and a lockfile `main` was
#      never tested with.
#   2. At `KERNEL_REF=c293ebd…` it stopped building at all. The base image's tree carries
#      workspace packages the PR #52 lockfile has never seen (`packages/solver-frontend`, the
#      poster's `deploy/scripts/lib/poster-*.ts`), so `bun install --frozen-lockfile` refused
#      with "lockfile had changes, but lockfile is frozen" (measured 2026-09-03).
#
# 00011 PR A answered (2) by moving `SOLVER_REF` onto `KERNEL_REF`, which made the overlay a
# no-op that still cost a fetch and a re-install. THIS file removes the mechanism: no source
# stage, no `SOLVER_REPO`/`SOLVER_REF`, no `.solver-commit`, no second `bun install`. The
# solver IS the kernel commit — exactly what the kernel repository's own `deploy/compose.yml`
# runs, where every one of these processes is the same `kernel-image` with a different
# entrypoint.
#
# ── ONE IMAGE, FOUR CONTAINERS ──────────────────────────────────────────────
# The same pattern images/offerfiles-kernel uses:
#
#   entrypoint-solver.sh            the long-running solver          (`bun run start.solver.ts`)
#   entrypoint-solver-frontend.sh   the read-only monitor site       (`start.solver-frontend.ts`)
#   entrypoint-solver-provision.sh  one-shot — give the solver inventory to trade with
#   entrypoint-maker-offer.sh       one-shot — seed the book with ONE real, settle-able offer
#
# ── WHY IT IS STILL A SEPARATE IMAGE AND NOT compose/offerfiles.yml's ───────
# `kernel-image` is a NAMED BUILD CONTEXT that compose wires to `service:kernel`, so this
# build starts from the image the offerfiles profile just built — including its compiled
# Compact artifacts (`…/contract-offer-files/src/managed`), which are gitignored upstream and
# exist only because that build compiled them. Compiling a second, independent copy would put
# two sets of verifier keys in one stack, which fails at settlement rather than at build.
# Keeping the solver's four entrypoints in their own context keeps the `solver` profile's
# concerns in the `solver` profile, and `service:kernel` also ORDERS the two builds.

FROM kernel-image

# ── the ledger-v8-only assertion ─────────────────────────────────────────────
# It now asserts the KERNEL image's own tree (there is no other), which is cheap and still
# meaningful: this stage runs on every solver build, so a base image that ever installs two
# ledger copies is caught here as well as in images/offerfiles-kernel.
#
# TWO ledger WASM copies in one process make every value that crosses between them fail
# `instanceof`, which presents as an unrelated type error deep inside a proof. This line is
# 1.x, so v8 must be present and v9 must be absent.
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

# The base image's identity, asserted rather than assumed: a `kernel-image` context wired to
# something that is not the offer-files kernel would otherwise only fail at settlement, when
# maker bytes are rebuilt against artifacts that do not match the contract.
#
# There is deliberately NO `.solver-commit` here any more. scripts/verify-source-pins.sh
# asserts its ABSENCE, because a second commit file is exactly what the retired overlay used
# to leave behind.
RUN test -f /app/.kernel-commit \
 && test ! -f /app/.solver-commit \
 && test -f /app/packages/contracts-midnight/contract-offer-files/src/managed/contract/index.js \
 && test -f /app/start.solver.ts \
 && test -f /app/start.solver-frontend.ts

# ── entrypoints ──────────────────────────────────────────────────────────────
# They source /usr/local/lib/offerfiles/entrypoint-common.sh from the KERNEL image underneath
# — the contract-adoption, Celestia-token and readiness-wait behaviour is identical for these
# containers, and a second copy of it would be a second thing to keep in step.
COPY entrypoint-solver.sh entrypoint-solver-frontend.sh \
     entrypoint-solver-provision.sh entrypoint-maker-offer.sh \
     /usr/local/bin/
RUN chmod 0755 /usr/local/bin/entrypoint-solver.sh \
               /usr/local/bin/entrypoint-solver-frontend.sh \
               /usr/local/bin/entrypoint-solver-provision.sh \
               /usr/local/bin/entrypoint-maker-offer.sh

# :9100 the solver's read-only status listener (network-internal, bearer-gated), :8080 the
# monitor site. Which one a container serves is decided by the entrypoint compose selects,
# never by this image.
EXPOSE 9100 8080

# No default command: a service that forgot to name its entrypoint must REFUSE rather than
# silently become a solver that trades.
CMD ["/bin/sh", "-c", "echo 'this image has no default command — select one of /usr/local/bin/entrypoint-{solver,solver-frontend,solver-provision,maker-offer}.sh' >&2; exit 64"]
