# intents-ui — the Midnight Intents browser app (Q5), built from YOUR OWN clone.
#
# Source: shieldedtech/midnight-intents-swaps @ RELAY_REF, subtree phase1-native-swaps — the
# vite SPA that lives at the root of that workspace, beside the relay it talks to. The
# repository is PRIVATE and this one is PUBLIC: the Q4 rules apply here in full and without
# exception. Not one byte of that source is committed; it arrives ONLY as the `reference`
# named build context fed from ${RELAY_SOURCE_DIR}, verified by up.sh before any build layer
# runs, and the image built from it is never pushed to any registry.
#
# ── the browser-network rule, and how this image satisfies it ────────────────
# NO COMPOSE-INTERNAL HOSTNAME MAY EVER REACH A BROWSER. `http://relay:3000` resolves inside
# the compose network and nowhere else, so a page that hands it to `fetch()` fails with
# ERR_NAME_NOT_RESOLVED on the operator's machine — the exact defect the zswap-da SPA's
# browser-network patch exists to prevent.
#
# This app needs no patch, because upstream already routes every relay call through a
# SAME-ORIGIN prefix (`/api/v1/...`) and expects an edge to strip it. So the edge is this
# image's nginx: the browser talks only to the published UI port, and nginx — server-side,
# inside the compose network — proxies to the relay. The only hostname the browser ever sees
# is its own. nginx.conf in this directory is OUR OWN, written for this deployment; upstream's
# is for a different topology and is not used.
#
# ── what is deliberately NOT solved here ────────────────────────────────────
# The app's swap flow needs a Midnight WALLET EXTENSION (`window.midnight`, the
# dapp-connector API) to sign an intent. That is a browser-profile concern this stack cannot
# provision: without an extension the page loads, lists the solver's tokens and quotes them
# live, but the final take cannot be driven headlessly. scripts/verify-solver.sh asserts
# exactly the part that is assertable and says so; the wallet half is a manual step.

# ── base images: index digests, not tags ─────────────────────────────────────
# Both are good official multiarch indexes (linux/amd64 + linux/arm64/v8 confirmed
# 2026-09-01 with `docker buildx imagetools inspect`), so nothing here forces a platform.
# The node major is upstream's own requirement (`engines: { node: ">=24" }`); the nginx line
# is the one the sibling repository's SPA image already uses, so this stack carries one
# static-server identity rather than two.
ARG NODE_BASE=node:24-alpine@sha256:e67514e5d0f6c46656005e1b693b2ec9d52e80b641307de684d4a015ba7a4eaf
ARG NGINX_BASE=nginx:1.27-alpine@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10

# ── 1. build the SPA ─────────────────────────────────────────────────────────
FROM ${NODE_BASE} AS builder

WORKDIR /app

# Same reason as images/relay/Dockerfile: upstream's `.npmrc` sets `engine-strict=true` plus
# three settings an older npm does not know, and `strict-npmrc=true` makes not knowing them a
# hard failure rather than a silent skip.
RUN npm i -g "npm@>=11.16" && npm --version

COPY --from=reference package.json package-lock.json .npmrc ./
COPY --from=reference scripts/ ./scripts/
COPY --from=reference packages/common/package.json ./packages/common/

RUN npm ci

# The shared workspace: the app imports its solver-reason strings from it (through a vite
# alias that resolves to the SOURCE, so the dev server works in a tree that was only
# installed), and other modules import the package's built entrypoint. Building it is what
# upstream's own `build:ui` script does first, for that second reason.
COPY --from=reference packages/common/tsconfig.json ./packages/common/
COPY --from=reference packages/common/src ./packages/common/src
RUN npm run build --workspace=packages/common

# The app itself.
COPY --from=reference index.html vite.config.ts tsconfig.json postcss.config.js tailwind.config.js ./
COPY --from=reference public/ ./public/
COPY --from=reference src/ ./src/

# ── the runtime configuration, baked ────────────────────────────────────────
# The app reads its configuration from a `<script id="config">` block in index.html, which
# vite's own config plugin fills from VITE_-prefixed variables at BUILD time. Written as a
# file rather than passed as an environment variable because the plugin's loader reads env
# FILES from the project directory, which is the behaviour that is specified rather than
# incidental.
#
# The network id is always set. Everything else the app needs has a same-origin default that
# is already correct for this deployment: the relay API base is `/api/v1` (nginx strips it),
# and the token LIST comes from the relay at runtime rather than from configuration — which is
# what makes this image independent of a chain whose token colours are minted fresh on every
# `./down.sh -v`.
ARG UI_NETWORK_ID=undeployed
RUN printf 'VITE_NETWORK_ID=%s\n' "${UI_NETWORK_ID}" > /app/.env

# Token NAMES are the one thing the relay cannot supply: `/tokens` carries raw colours, and the
# app's `tokenNames` module labels a colour by the `TOKEN_<NAME>` config key it finds in the
# baked config block (a `VITE_TOKEN_<NAME>=<64-hex>` line here), falling back to the colour's
# last 8 hex chars. So this is a BUILD-time knob, and because colours are minted per chain the
# value lives in each stack's `.env` (INTENTS_UI_TOKEN_NAMES), never in a committed default.
# The label the app shows is the whole key, `TOKEN_<NAME>` — that is upstream's convention
# (its own preprod config names tokens TOKEN_A…TOKEN_J) and not something this image changes.
# Malformed entries fail the build rather than silently producing an unlabeled token.
ARG UI_TOKEN_NAMES=
RUN set -eu; \
    IFS=','; for pair in ${UI_TOKEN_NAMES}; do \
      [ -n "${pair}" ] || continue; \
      name="${pair%%=*}"; hex="${pair#*=}"; \
      case "${name}" in \
        ""|*[!A-Z0-9_]*) echo "FAIL: UI_TOKEN_NAMES entry '${pair}': name must be A-Z, 0-9 or _" >&2; exit 1 ;; \
      esac; \
      case "${hex}" in \
        ????????????????????????????????????????????????????????????????) : ;; \
        *) echo "FAIL: UI_TOKEN_NAMES entry '${pair}': colour must be exactly 64 hex chars" >&2; exit 1 ;; \
      esac; \
      case "${hex}" in \
        *[!0-9a-f]*) echo "FAIL: UI_TOKEN_NAMES entry '${pair}': colour must be lowercase hex" >&2; exit 1 ;; \
      esac; \
      printf 'VITE_TOKEN_%s=%s\n' "${name}" "${hex}" >> /app/.env; \
    done; \
    cat /app/.env

RUN npx vite build --outDir dist-ui \
 && test -f /app/dist-ui/index.html \
 && grep -q 'id="config"' /app/dist-ui/index.html

# Every configured name must have reached the baked config block — the plugin reads env FILES
# and a silently ignored line would ship a UI that shows hex tails again.
RUN set -eu; \
    IFS=','; for pair in ${UI_TOKEN_NAMES}; do \
      [ -n "${pair}" ] || continue; \
      grep -q "\"TOKEN_${pair%%=*}\":\"${pair#*=}\"" /app/dist-ui/index.html \
        || { echo "FAIL: TOKEN_${pair%%=*} did not reach the baked config block" >&2; exit 1; }; \
    done

# ── 2. serve it ──────────────────────────────────────────────────────────────
FROM ${NGINX_BASE}

COPY --from=builder /app/dist-ui /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Which commit this image is — stamped from the build arg, for the same reason and with the
# same honest limitation as images/relay/Dockerfile: the named context carries no .git, so
# this records what up.sh verified rather than verifying it here.
# scripts/verify-source-pins.sh reads it back out of the built image.
ARG RELAY_REF
RUN test -n "${RELAY_REF}" || { echo "FAIL: RELAY_REF build arg is required" >&2; exit 1; }; \
    case "${RELAY_REF}" in \
      ????????????????????????????????????????) : ;; \
      *) echo "FAIL: RELAY_REF must be a full 40-character commit SHA, got '${RELAY_REF}'" >&2; exit 1 ;; \
    esac; \
    printf '%s\n' "${RELAY_REF}" > /.intents-ui-commit

# 8080, not 80: an unprivileged port, and the same convention the rest of this stack follows.
EXPOSE 8080
