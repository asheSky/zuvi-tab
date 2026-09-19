#!/bin/bash
# Fails if a binary imports any networking API. Used by build.sh and by CI on every push.
# Usage: scripts/check-no-network.sh <binary>
set -euo pipefail
bin="${1:?usage: $0 <binary>}"
# Undefined (imported) symbols only. One symbol per line, so ^...$ anchors are exact on any grep.
symbols=$(nm -u "$bin")
pattern='URLSession|URLRequest|NSURLConnection|NWConnection|NWListener|NWBrowser|nw_connection|nw_endpoint|CFSocket|CFStreamCreatePairWithSocket|CFHTTP|^_socket$|^_connect$|^_getaddrinfo$|^_gethostbyname$|^_sendto$|^_recvfrom$|^_bind$|^_listen$'
if hits=$(printf '%s\n' "$symbols" | grep -E "$pattern"); then
    echo "ERROR: networking symbols found in $bin:" >&2
    printf '%s\n' "$hits" | head -20 >&2
    exit 1
fi
echo "No networking symbols in $(basename "$bin")."
