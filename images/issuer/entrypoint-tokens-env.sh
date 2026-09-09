#!/usr/bin/env bash
# issuer-tokens-env — RE-PUBLISH the shell-sourceable token handoff. READ-ONLY on the chain.
#
#   docker compose run --rm --no-deps issuer-tokens-env
#
# `entrypoint-deploy.sh` already writes `${ISSUER_TOKENS_DIR}/tokens.env` on both its deploy
# and its resume path, so this command exists for two narrower jobs:
#
#   * REPAIR — the `issuer-tokens` volume was removed (or `./down.sh` kept the registry volume
#     and not this one) while the registry is still valid for this chain. Re-running
#     `issuer-deploy` would work too, but it opens the issuer's wallet facade and takes the
#     genesis lock to do a job that needs neither.
#   * INSPECTION — `cat` the projection an operator's consumers are actually reading, and see
#     the same ids `issuer-registry` prints, in the form the containers consume them.
#
# It holds NO wallet and NO seed, touches no chain and takes no lock: it reads the registry
# through the same validating loader every other consumer uses (`m1/registry.ts`'s
# `loadReadyRegistry`) and writes one file. `--no-deps` is enough and it costs a second.
#
# EXIT CODES: 0 published; 1 no registry, an invalid registry, or a value that failed its
# shape check (the message names the token and the field).

# Consumed by log() in the sourced prelude, which shellcheck cannot see from here.
# shellcheck disable=SC2034
ROLE=issuer-tokens-env
# shellcheck source=images/issuer/entrypoint-common.sh
. /usr/local/lib/issuer/entrypoint-common.sh

[ -f "${ISSUER_REGISTRY_FILE}" ] || {
  log "no registry at ${ISSUER_REGISTRY_FILE}"
  log "run the issuer-deploy one-shot first: docker compose run --rm issuer-deploy"
  exit 78
}

# The reader resolves the registry through MN_METADATA_OUTPUT_DIR, exactly as every other
# consumer in this image does.
export MN_METADATA_OUTPUT_DIR="${ISSUER_REGISTRY_DIR}"

cd "${REPO_ROOT}" || die "no ${REPO_ROOT}"
exec node --import tsx "${REPO_ROOT}/m1/tokens-env.ts"
