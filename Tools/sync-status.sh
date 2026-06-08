#!/usr/bin/env bash
# Snapshot of the local defradb sidecar's sync state.
#
# Run on either Mac. Prints:
#   - This Mac's libp2p multiaddrs (paste the /ip4/192.x or /ip4/10.x one elsewhere)
#   - Collection IDs (must match line-for-line on the other Mac)
#   - Row counts per collection (the master has the data; the receiver should be 0 until sync)
#   - Pubsub subscription list
#   - Currently-active libp2p peers
#
# Use this to compare two Macs side-by-side before/after wiring replication.

set -uo pipefail

PORT="${DEFRA_PORT:-9181}"
URL="http://127.0.0.1:${PORT}"
COLLECTIONS=(SleepSession DailyMetric Journal Workout AppleDaily)

DEFRADB="${DEFRADB:-$HOME/Repos/scratchpad/whoop/noop/Tools/defradb/defradb-darwin-arm64}"

if ! curl -fsS --max-time 2 "${URL}/api/v0/p2p/info" >/dev/null 2>&1; then
    echo "❌ No sidecar responding at ${URL}. Is Strand running with sync enabled?" >&2
    exit 1
fi

hr() { printf '\n=== %s ===\n' "$1"; }

hr "This Mac's multiaddrs"
echo "(Copy the /ip4/192.x or /ip4/10.x address for the other Mac to dial.)"
curl -s "${URL}/api/v0/p2p/info" | jq

hr "Collection IDs (must match line-for-line on the other Mac)"
"${DEFRADB}" client collection describe --url "127.0.0.1:${PORT}" \
    | jq '.[] | {Name, CollectionID}'

hr "Defradb row counts per collection"
for T in "${COLLECTIONS[@]}"; do
    N=$(curl -s -X POST "${URL}/api/v0/graphql" -H 'Content-Type: application/json' \
        -d "{\"query\":\"{ $T { _docID } }\"}" | jq ".data.$T | length" 2>/dev/null)
    printf "  %-14s %s\n" "$T" "${N:-?}"
done

hr "Pubsub subscriptions"
curl -s "${URL}/api/v0/p2p/collections" | jq

hr "Currently-active libp2p peers"
curl -s "${URL}/api/v0/p2p/active-peers" | jq

hr "Configured replicators (forward push targets)"
curl -s "${URL}/api/v0/p2p/replicators" | jq

echo
echo "✓ done"
