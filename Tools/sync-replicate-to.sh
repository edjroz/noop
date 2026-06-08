#!/usr/bin/env bash
# Tell the LOCAL defradb sidecar to mirror all five sync collections to a peer.
#
# Run this on the Mac that HAS the data (the "master"). It registers a forward-push
# replicator for each collection, so every existing row plus future writes are pushed
# to the peer's multiaddr.
#
# Usage:
#   ./Tools/sync-replicate-to.sh /ip4/192.168.1.158/tcp/9171/p2p/12D3KooW...
#
# This is the WORKING-AROUND-THE-APP version of what SyncController's "Connect to peer"
# button should be doing. Adding it via the CLI directly lets us prove the data path
# end-to-end without touching the Swift code.

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $(basename "$0") <peer multiaddr>" >&2
    exit 2
fi
PEER="$1"

PORT="${DEFRA_PORT:-9181}"
URL="http://127.0.0.1:${PORT}"
DEFRADB="${DEFRADB:-$HOME/Repos/scratchpad/whoop/noop/Tools/defradb/defradb-darwin-arm64}"
COLLECTIONS=(SleepSession DailyMetric Journal Workout AppleDaily)

if ! curl -fsS --max-time 2 "${URL}/api/v0/p2p/info" >/dev/null 2>&1; then
    echo "❌ No sidecar responding at ${URL}. Is Strand running with sync enabled?" >&2
    exit 1
fi

# Build -c CollectionName flags for every collection in one shot.
CFLAGS=()
for c in "${COLLECTIONS[@]}"; do
    CFLAGS+=(-c "$c")
done

echo "→ Telling defradb to replicate ${COLLECTIONS[*]} to:"
echo "  ${PEER}"
"${DEFRADB}" client p2p replicator add --url "127.0.0.1:${PORT}" "${CFLAGS[@]}" "${PEER}"

echo
echo "→ Replicator list after add:"
curl -s "${URL}/api/v0/p2p/replicators" | jq

echo
echo "✓ done. Run ./Tools/sync-watch.sh on the peer to see rows arrive."
