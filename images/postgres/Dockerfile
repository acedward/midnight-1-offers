# postgres — the ONE PostgreSQL for the whole stack.
#
# Ported from midnight-2-offers/images/postgres. The 2.x server had TWO consumers
# (`umbra` for umbra-evm, `offerfiles` for the offer-files kernel); this repository
# has no EVM profile, so there is exactly ONE database and one role: `offerfiles`.
# See initdb/10-databases.sh.
#
# It still lives in the CORE profile rather than in `offerfiles`, for the same
# reason it did in the 2.x sibling: an idle Postgres costs almost nothing, and a
# server-per-profile is a second set of volumes, healthchecks and teardown rules
# to keep straight. Core owns the shared infrastructure; profiles own consumers.
#
# ─── WHY THIS IS NOT JUST `postgres:17-alpine` ──────────────────────────────
# The offer-files kernel needs the `pg_ivm` extension — incrementally maintained
# materialized views. It is NOT optional by default: @effectstream/db's
# capabilities.ts THROWS at startup when pg_ivm is missing unless
# ALLOW_NO_PG_IVM=true, and that flag itself defaults to false. The fallback it
# unlocks is a plain-SQL view strategy the package's own docs describe as
# degrading sharply on high-cardinality data.
#
# This matters more here than it did in 2.x, because Q7 chose Postgres over the
# PGLite sidecar the 1.x kernel was actually developed against — and PGLite DOES
# ship pg_ivm. A stock postgres:17-alpine would therefore have been a SILENT
# DEMOTION of kernel main from its production read path to the degraded one, with
# no error to point at it. The extension is compiled in here so the kernel keeps
# exactly the behaviour PGLite gave it.
#
# Pinned to an upstream release tarball rather than a floating clone, for the same
# reason every other artifact in this repository is pinned.

ARG PG_TAG=17-alpine

# ── stage 1: compile pg_ivm against this exact server version ───────────────
FROM postgres:${PG_TAG} AS build

ARG PG_IVM_VERSION=1.11

# `with_llvm=no` below is not laziness: this Alpine has no clang19/llvm19 package,
# and LLVM is only used to emit optional JIT bitcode. The extension itself builds
# and runs fine without it.
RUN apk add --no-cache build-base postgresql17-dev curl tar

RUN set -eux; \
    curl --proto '=https' --tlsv1.2 -fLsS -o /tmp/pg_ivm.tar.gz \
      "https://github.com/sraoss/pg_ivm/archive/refs/tags/v${PG_IVM_VERSION}.tar.gz"; \
    mkdir -p /tmp/src; \
    tar -xzf /tmp/pg_ivm.tar.gz -C /tmp/src --strip-components=1; \
    cd /tmp/src; \
    make USE_PGXS=1 with_llvm=no; \
    make USE_PGXS=1 with_llvm=no install; \
    # Fail the BUILD if the artifacts are not where the server will look for them
    # — a missing .so would otherwise surface much later as a kernel startup abort.
    test -f /usr/local/lib/postgresql/pg_ivm.so; \
    test -f /usr/local/share/postgresql/extension/pg_ivm.control

# ── stage 2: the runtime image ──────────────────────────────────────────────
FROM postgres:${PG_TAG}

# Only the extension's own artifacts — none of the build toolchain.
COPY --from=build /usr/local/lib/postgresql/pg_ivm.so /usr/local/lib/postgresql/
COPY --from=build /usr/local/share/postgresql/extension/pg_ivm* /usr/local/share/postgresql/extension/

# Runs ONCE, on an empty data directory, in filename order. Creates the consumer
# database + role and pre-installs pg_ivm in it as the superuser, so an app role
# never needs superuser to satisfy its own best-effort
# `CREATE EXTENSION IF NOT EXISTS pg_ivm`.
COPY initdb/ /docker-entrypoint-initdb.d/

# Deliberately no host port in compose: this server is reachable only on the
# compose network, and one unpublished port is one less collision on a shared
# machine. Reach it with
#   docker compose ... exec postgres psql -U offerfiles offerfiles
EXPOSE 5432
