#!/bin/bash
#
# proof-warm — populate the shared `proof-data` volume, ONCE, before any reader looks at it.
#
# Runs INSIDE the official proof-server image (same digest as the `proof-server` service —
# see compose/core.yml). It is bind-mounted in rather than baked into an image of its own,
# so this repository adds no base-image pin for a fifteen-line one-shot.
#
# ── WHY THIS EXISTS, MEASURED (P1/T1.3, 2026-09-01) ─────────────────────────────────────
#
# On a cold MIDNIGHT_PP the proof server downloads its whole startup working set BEFORE it
# binds its port — measured 32.6 MB in ~4 s: SRS bls_midnight_2p10…2p15 plus
# zswap/9/{spend,output,sign}.{prover,verifier,bzkir} and dust/9/spend.*. Every one of those
# fetches is HASH-VERIFIED against values compiled into the ledger-8.1.0 binary; the server
# says so itself ("this is not a trusted service, the data will be verified") and logs
# "verified correct" per payload.
#
# That measurement is why this script warms the cache by RUNNING THE SERVER rather than by
# curling the payloads. A curl-based pre-fill would write bytes nothing verifies, and the
# server does not re-check a file it finds already on disk — it verifies only on download.
# So the obvious implementation would have been a strict integrity DOWNGRADE. Here every
# warmed byte is fetched and verified by exactly the code that will later consume it.
#
# It is also not optional. compose/core.yml mounts the cache READ-ONLY in `proof-server`
# (one writer, per scripts/lib/compose_pins.py). A server pointed at an empty read-only
# MIDNIGHT_PP does not degrade gracefully — it exits 1 in under a second with
# `Os { code: 30, kind: ReadOnlyFilesystem }`. This one-shot is what makes the server
# startable at all.
#
# KNOWN GAP, carried as Q11: this warms only what the binary fetches at startup. A
# contract-sized circuit needing a larger SRS k (k16+) would hit EROFS at prove time rather
# than fetching it. Which k the offer-files contract needs cannot be known until a contract
# exists (P2/P3), and fetching it by URL is the downgrade described above.
#
# DROP-IN SEAM: when the audited v8 proof-data generation lands, its initializer replaces
# THIS SERVICE as the writer of the same volume at the same mount point. No consumer changes.
#
set -euo pipefail

# The image sets PATH to the ledger bin directory ONLY, so /bin is not on it even though the
# image ships a full GNU coreutils there. Put it back rather than absolute-pathing every
# call. `midnight-proof-server` itself stays on PATH: its /nix/store directory differs
# between linux/amd64 and linux/arm64, so resolving it by name is what keeps this portable.
PATH="/bin:/usr/bin:${PATH}"
export PATH

PP="${MIDNIGHT_PP:?MIDNIGHT_PP must name the cache directory}"
PORT="${PROOF_WARM_PORT:-6300}"
TIMEOUT="${PROOF_WARM_TIMEOUT:-900}"

say() { printf '[proof-warm] %s\n' "$*"; }

say "cache      ${PP}"
say "source     ${MIDNIGHT_PARAM_SOURCE:-<image default>}"
say "budget     ${TIMEOUT}s"

if [[ ! -d "$PP" ]]; then
  say "FAIL: ${PP} is not a directory — the volume is not mounted"
  exit 1
fi
# Fail here, with a sentence, rather than letting the server die on an opaque EROFS. This is
# the writer; if it cannot write, the mount is wrong.
if ! touch "$PP/.proof-warm-write-test" 2>/dev/null; then
  say "FAIL: ${PP} is not writable — proof-warm is the ONE writer of this volume and must"
  say "      mount it read-write (readers mount it :ro)"
  exit 1
fi
rm -f "$PP/.proof-warm-write-test"

# ── run the official server just long enough to populate and verify the cache ────────────
say "starting the proof server to perform its own verified fetch"
midnight-proof-server --port "$PORT" &
SERVER_PID=$!

# ready_probe — one HTTP GET /ready over bash's /dev/tcp builtin. The image has no curl and
# no wget; /dev/tcp needs neither. The port opens only AFTER the fetch-and-verify completes,
# so "answers 200" is precisely "the cache is warm".
ready_probe() {
  local line
  exec 3<>"/dev/tcp/127.0.0.1/${PORT}" 2>/dev/null || return 1
  printf 'GET /ready HTTP/1.0\r\n\r\n' >&3 || { exec 3<&-; return 1; }
  read -r line <&3 || { exec 3<&- 2>/dev/null; return 1; }
  exec 3<&- 2>/dev/null
  exec 3>&- 2>/dev/null
  case "$line" in
    *" 200 "*) return 0 ;;
    *) return 1 ;;
  esac
}

WARM=0
START=$SECONDS
while (( SECONDS - START < TIMEOUT )); do
  # A dead server is a hard failure, not something to wait out: its own log above already
  # says why (a failed fetch, a bad MIDNIGHT_PARAM_SOURCE, a read-only mount).
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    wait "$SERVER_PID" 2>/dev/null || true
    say "FAIL: the proof server exited before the cache was warm (see its log above)"
    exit 1
  fi
  if ready_probe; then
    WARM=1
    break
  fi
  sleep 2
done

ELAPSED=$(( SECONDS - START ))

# Stop the server before reporting: this is a one-shot, and compose waits on its exit code.
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true

if (( ! WARM )); then
  say "FAIL: the cache was not warm within ${TIMEOUT}s"
  exit 1
fi

# ── report what actually landed ──────────────────────────────────────────────────────────
# An exit code alone cannot distinguish "warmed 32 MB" from "wrote nothing and answered
# anyway", so the contents are counted and printed every run.
#
# Enumerated with bash's globstar, NOT with `find`: this image ships GNU coreutils in /bin
# but NOT findutils, so `find` is absent and calling it exits 127. `du`, `wc`, `sort` and
# `stat` ARE coreutils and are present.
shopt -s globstar nullglob dotglob
PATHS=("$PP"/**)
FILE_LIST=()
for p in ${PATHS[@]+"${PATHS[@]}"}; do
  [[ -f "$p" ]] && FILE_LIST+=("$p")
done
FILES=${#FILE_LIST[@]}
BYTES=$(du -sh "$PP" 2>/dev/null | cut -f1)

say "warm in ${ELAPSED}s — ${FILES} file(s), ${BYTES:-?}"
for p in ${FILE_LIST[@]+"${FILE_LIST[@]}"}; do
  printf '%12s  %s\n' "$(stat -c %s "$p" 2>/dev/null || echo '?')" "${p#"$PP"/}"
done | sort -k2

if (( FILES == 0 )); then
  say "FAIL: the server reported ready but the cache is EMPTY — refusing to hand an empty"
  say "      volume to a read-only reader that will exit 1 on it"
  exit 1
fi

say "done — the proof server may now mount this volume read-only"
