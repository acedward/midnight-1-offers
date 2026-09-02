#!/bin/sh
#
# Write /config.js from the container environment, then exec nginx.
#
# The SPA reads its endpoints from `window.*` before the bundle evaluates (index.html loads
# /config.js first). Everything here is therefore RUNTIME configuration of an image that was
# built once: the same image serves a default-port stack and a random-port stack.
#
#   API_BASE          -> window.API_BASE           kernel API base   (src/config.ts)
#   BATCHER_URL       -> window.BATCHER_URL        batcher base      (src/config.ts)
#   NODE_URI          -> window.NODE_URI           }
#   INDEXER_URI       -> window.INDEXER_URI        } overrides applied to the kernel's
#   INDEXER_WS_URI    -> window.INDEXER_WS_URI     } GET /v1/midnight/config
#   PROOF_SERVER_URI  -> window.PROOF_SERVER_URI   }   (upstream api.getMidnightConfig, effectstream#912)
#
# An EMPTY value is skipped, not written as an empty string: `window.X = ""` would defeat the
# template's `??` fallbacks, and the fallbacks are correct on the default port block.
#
# POSIX sh: the nginx alpine base has no bash.
set -eu

TARGET=/usr/share/nginx/html/config.js

# A literal newline, for the injection check below. `$(printf '\n')` cannot be used: command
# substitution strips trailing newlines, so it yields the EMPTY string and the guard pattern
# `*""*` would then match every value and reject all of them.
NL='
'

# emit <window-property> <value>
#
# The value is interpolated into a JavaScript string literal, so a quote, a backslash or a
# newline in it would not merely break the page — it would inject code into every browser that
# loads it. These values are URLs from the operator's own .env; the check costs nothing and
# turns a typo into a startup failure instead of a broken bundle nobody can explain.
emit() {
    [ -n "$2" ] || return 0
    case "$2" in
        *[\"\\]* | *"$NL"*)
            echo "FAIL: ${1} contains a quote, backslash or newline: ${2}" >&2
            exit 1
            ;;
    esac
    printf 'window.%s = "%s";\n' "$1" "$2"
}

{
    printf '%s\n' '// Generated at container start by images/zswap-da/entrypoint.sh.'
    emit API_BASE         "${API_BASE:-}"
    emit BATCHER_URL      "${BATCHER_URL:-}"
    emit NODE_URI         "${NODE_URI:-}"
    emit INDEXER_URI      "${INDEXER_URI:-}"
    emit INDEXER_WS_URI   "${INDEXER_WS_URI:-}"
    emit PROOF_SERVER_URI "${PROOF_SERVER_URI:-}"
} > "$TARGET"

echo "zswap-da: wrote $(wc -l < "$TARGET") line(s) to ${TARGET}"
sed 's/^/    /' "$TARGET"

exec nginx -g 'daemon off;'
