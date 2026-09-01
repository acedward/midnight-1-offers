# relay — the Midnight Intents relay, UNMODIFIED, built from YOUR OWN clone.
#
# Source: shieldedtech/midnight-intents-swaps @ RELAY_REF, subtree phase1-native-swaps.
# That repository is PRIVATE and this one is PUBLIC, so the rule (spec FR-11, plan Q4) is
# absolute: NOT ONE BYTE of it is committed here. This file is OUR TRANSCRIPTION of the
# upstream recipe — it contains no copied code, and every line that reads upstream source is
# visibly marked `--from=reference`.
#
# ── how the source gets in ───────────────────────────────────────────────────
# `reference` is a NAMED BUILD CONTEXT. compose/solver.yml wires it to ${RELAY_SOURCE_DIR},
# the operator's own checkout, and up.sh verifies that checkout sits at exactly RELAY_REF
# with a clean tree BEFORE any build starts (scripts/lib/common.sh assert_relay_source).
# A named context, rather than `context:` pointed at the clone, keeps the private location
# out of this repository entirely: it arrives from the operator's environment and never
# becomes a path anything here knows.
#
# WHAT THIS BUILD CANNOT DO, said plainly: it cannot verify the source itself. Every other
# image here fetches `--depth 1 origin <full sha>`, so git checks the identity for free. A
# directory proves nothing about itself, so the check lives in up.sh instead and the commit
# is merely STAMPED here (/app/.relay-commit) for scripts/verify-source-pins.sh to compare
# against the matrix. Stamping is not verifying, and the difference is the whole reason
# assert_relay_source() runs first.
#
# ── why a transcription rather than the upstream Dockerfile ──────────────────
# The reference ships its own relay Dockerfile and this follows it faithfully: same base,
# same stage split, the same `npm ci` -> build common -> build relay -> `npm prune
# --omit=dev` sequence, and the same supervisord conf running the relay entrypoint as PID 1's
# child. Transcribed so that anything build-side this deployment needs — a base pin, an npm
# bootstrap, a build fix — has somewhere to live that is NOT the private tree. Using their
# Dockerfile in place works today and leaves nowhere to put the first fix.
#
# Deliberate divergences from the upstream recipe, all build-side:
#   1. `COPY --from=reference` instead of plain COPY (see above).
#   2. `npm i -g npm@>=11.16` in the builder (see the comment at that line).
#   3. Workspaces are built BY PATH (`--workspace=packages/relay`), not by their scoped
#      package names. npm accepts either; the path form is used because the scope name is a
#      private-source marker this public repository must not carry (scripts/lib/leak_scan.py
#      rejects it in any context, comments included).
#   4. EXPOSE lists only the two ports this deployment publishes; upstream also exposes
#      80/443 for a standalone ACME mode that is off here.
#   5. The wallet-cache directory is pre-created and chowned, because compose mounts a volume
#      onto it and the runtime user is not root.

# ── base image: index digest, not a tag ──────────────────────────────────────
# Good official multiarch index (linux/amd64 + linux/arm64/v8 confirmed 2026-09-01 with
# `docker buildx imagetools inspect`), so no `platform:` pin and both architectures build
# native. A tag is not an identity: `node:24-alpine` can be repointed at different bytes
# without one character of this repository changing. The MAJOR is upstream's own choice —
# its package.json declares `engines: { node: ">=24" }`.
ARG NODE_BASE=node:24-alpine@sha256:e67514e5d0f6c46656005e1b693b2ec9d52e80b641307de684d4a015ba7a4eaf

# ── 1. builder ───────────────────────────────────────────────────────────────
FROM ${NODE_BASE} AS builder

WORKDIR /app

# Upstream's root package.json declares `engines: { npm: ">=11.16" }` and its `.npmrc` sets
# `engine-strict=true`, which turns an older bundled npm into a hard `npm ci` failure rather
# than a warning. That same `.npmrc` also sets `min-release-age` (a supply-chain cooldown),
# `strict-allow-scripts` and `strict-npmrc` — and the last of those makes an npm that does
# not recognise the others FAIL rather than skip them. Upgrading the build tool is the only
# way to satisfy that from a base image we do not control, and it changes nothing about the
# relay itself.
RUN npm i -g "npm@>=11.16" && npm --version

# Workspace metadata first: the dependency graph changes far less often than the source, so
# this layer survives most rebuilds.
COPY --from=reference package.json package-lock.json .npmrc ./
COPY --from=reference scripts/ ./scripts/
COPY --from=reference packages/common/package.json ./packages/common/
COPY --from=reference packages/relay/package.json ./packages/relay/

RUN npm ci

# Common source + tsconfig (the relay's tsconfig declares it as a project reference).
COPY --from=reference packages/common/tsconfig.json ./packages/common/
COPY --from=reference packages/common/src ./packages/common/src

# Relay source + tsconfig.
COPY --from=reference packages/relay/tsconfig.json ./packages/relay/
COPY --from=reference packages/relay/src ./packages/relay/src

RUN npm run build --workspace=packages/common
RUN npm run build --workspace=packages/relay
# The build script can succeed while emitting nothing useful (a tsconfig with no outDir, a
# renamed entrypoint). Assert the artifact the runtime stage actually starts.
RUN test -f packages/relay/dist/relay-main.js

RUN npm prune --omit=dev --workspaces --include-workspace-root

# ── 2. runtime ───────────────────────────────────────────────────────────────
FROM ${NODE_BASE} AS runtime

WORKDIR /app

RUN apk add --no-cache supervisor \
 && addgroup -S relay && adduser -S relay -G relay

COPY --from=builder --chown=relay:relay /app ./
COPY --from=reference infra/supervisord.relay.conf /etc/supervisord.conf

# WALLET_CACHE_DIR is the relay's only stateful path, and compose mounts a named volume onto
# it. A volume mounted over a directory that does not exist is created ROOT-OWNED, which a
# non-root runtime user then cannot write — so it is created and chowned here.
RUN mkdir -p /app/data/wallet-sync-cache && chown -R relay:relay /app/data

# WHICH COMMIT THIS IMAGE IS. Stamped from the build arg, NOT derived from the source (the
# named context carries no .git — RELAY_SOURCE_DIR points at a subdirectory of the clone, so
# the repository metadata is outside the context by construction). up.sh proved the clone was
# at this commit before the build began; scripts/verify-source-pins.sh reads this file back
# out of the built image and compares it with config/artifact-decisions.json.
ARG RELAY_REF
RUN test -n "${RELAY_REF}" || { echo "FAIL: RELAY_REF build arg is required" >&2; exit 1; }; \
    case "${RELAY_REF}" in \
      ????????????????????????????????????????) : ;; \
      *) echo "FAIL: RELAY_REF must be a full 40-character commit SHA, got '${RELAY_REF}'" >&2; exit 1 ;; \
    esac; \
    printf '%s\n' "${RELAY_REF}" > /app/.relay-commit

USER relay

# 3000 HTTP (POST /quote, POST /intent, GET /jobs/:jobId, GET /tokens, and a loopback-ONLY
# GET /state) and 9001 the solver-facing WebSocket. There is NO /health route — compose
# probes GET /tokens instead, which answers 200 with an empty list when no solver is
# connected, i.e. exactly the "serving but idle" state that should read as healthy.
EXPOSE 3000 9001

# supervisord is PID 1 and restarts the relay on crash; its program block comes from the
# reference's own conf, copied at build time above.
CMD ["supervisord", "-c", "/etc/supervisord.conf"]
