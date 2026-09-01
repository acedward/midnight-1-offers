#!/usr/bin/env bash
# wait-for.sh — readiness waits for the offer-files entrypoints. SOURCED, never executed.
#
# WHY THIS FILE EXISTS INSTEAD OF THE KERNEL'S OWN PREFLIGHT. The 2.x sibling stack runs
# `bun run packages/node/preflight-external.ts` as each container's first act. Kernel MAIN
# has no such file — that module belongs to the v9 lineage — so the external-stack probe
# lives here rather than being borrowed from a source tree that does not contain it.
#
# Everything is done with `bun -e`. The oven/bun base image ships no curl and no wget, and
# installing one purely for a readiness probe would grow all three containers for nothing.
#
# EVERY wait FAILS the caller rather than warning. A container that starts against a
# half-ready stack does not fail here — it fails later, somewhere unrelated, with an error
# that names the wrong component.

_wf_log() { echo "[wait-for] $*" >&2; }

# wait_http <url> <label> [timeout_s]
#
# ANY HTTP response counts as "listening", including a 404 or a 500: what is being waited on
# is a socket that answers, not a particular status. A service that answers 500 is a service
# whose own healthcheck should be complaining, not something for a dependency to interpret.
wait_http() {
  local url="$1" label="$2" timeout="${3:-180}" waited=0
  _wf_log "waiting for ${label} at ${url} (timeout ${timeout}s)"
  until bun -e '
    const r = await fetch(process.argv[1], { signal: AbortSignal.timeout(4000) }).catch(() => null);
    process.exit(r ? 0 : 1);
  ' "${url}" >/dev/null 2>&1; do
    waited=$(( waited + 2 ))
    if [ "${waited}" -ge "${timeout}" ]; then
      _wf_log "TIMEOUT after ${timeout}s waiting for ${label} at ${url}"
      return 1
    fi
    sleep 2
  done
  _wf_log "${label} is up"
}

# wait_tcp <host> <port> <label> [timeout_s]
# For anything that does not speak HTTP — in this image, PostgreSQL.
wait_tcp() {
  local host="$1" port="$2" label="$3" timeout="${4:-180}" waited=0
  _wf_log "waiting for ${label} at tcp://${host}:${port} (timeout ${timeout}s)"
  until bun -e '
    const [host, port] = [process.argv[1], Number(process.argv[2])];
    try {
      const socket = await Bun.connect({ hostname: host, port, socket: { data() {} } });
      socket.end();
      process.exit(0);
    } catch { process.exit(1); }
  ' "${host}" "${port}" >/dev/null 2>&1; do
    waited=$(( waited + 2 ))
    if [ "${waited}" -ge "${timeout}" ]; then
      _wf_log "TIMEOUT after ${timeout}s waiting for ${label} at tcp://${host}:${port}"
      return 1
    fi
    sleep 2
  done
  _wf_log "${label} is up"
}

# wait_node_block <http-rpc-url> [min-block] [timeout_s]
#
# Compose health is not readiness for a Substrate chain: the node answers RPC long before it
# has produced anything, and two consumers need a real block. No transaction can be built
# against an empty chain, and the indexer's bundled spo-indexer reads block #1 on a fresh
# database and exit(1)s when it is missing — which is why the kernel repository's own
# indexer launcher gates on the same condition.
wait_node_block() {
  local url="$1" min_block="${2:-1}" timeout="${3:-300}" waited=0
  _wf_log "waiting for midnight-node block #${min_block} at ${url} (timeout ${timeout}s)"
  until bun -e '
    const [url, minBlock] = [process.argv[1], Number(process.argv[2])];
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "chain_getBlockHash", params: [minBlock] }),
      signal: AbortSignal.timeout(5000),
    }).catch(() => null);
    if (!res) process.exit(1);
    const json = await res.json().catch(() => null);
    process.exit(json && json.result ? 0 : 1);
  ' "${url}" "${min_block}" >/dev/null 2>&1; do
    waited=$(( waited + 2 ))
    if [ "${waited}" -ge "${timeout}" ]; then
      _wf_log "TIMEOUT after ${timeout}s waiting for block #${min_block} at ${url}"
      return 1
    fi
    sleep 2
  done
  _wf_log "midnight-node has block #${min_block}"
}
