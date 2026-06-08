#!/usr/bin/env bash
# Watch defradb row counts climb on this Mac. Use after `sync-replicate-to.sh` was run on
# the master Mac. Reports per-collection counts + active-peer list every 3s.
#
# Exit condition is "no growth for STABLE_S seconds in a row" — defaults to 60s, because
# v1.0.0-rc1's replicator throughput can be glacial (sometimes one doc per ~20s) and a
# shorter window made us think sync had stopped when it was just slow. Adjust if needed.
#
# Usage:
#   ./Tools/sync-watch.sh                    # 5 min timeout, 60s stable window
#   ./Tools/sync-watch.sh 900                # 15 min timeout, 60s stable window
#   ./Tools/sync-watch.sh 900 30             # 15 min timeout, 30s stable window

set -uo pipefail

TIMEOUT_S="${1:-300}"
STABLE_S="${2:-60}"
PORT="${DEFRA_PORT:-9181}"
URL="http://127.0.0.1:${PORT}"
COLLECTIONS=(SleepSession DailyMetric Journal Workout AppleDaily)

if ! curl -fsS --max-time 2 "${URL}/api/v0/p2p/info" >/dev/null 2>&1; then
    echo "❌ No sidecar responding at ${URL}. Is Strand running with sync enabled?" >&2
    exit 1
fi

count_for() {
    curl -s -X POST "${URL}/api/v0/graphql" -H 'Content-Type: application/json' \
        -d "{\"query\":\"{ $1 { _docID } }\"}" | jq ".data.$1 | length" 2>/dev/null
}

STARTED=$(date +%s)
PREV_SIG=""
LAST_CHANGE_AT=$(date +%s)

echo "Watching for up to ${TIMEOUT_S}s. Exits when counts don't grow for ${STABLE_S}s in a row."
echo

while :; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - STARTED))
    if (( ELAPSED >= TIMEOUT_S )); then
        echo "⏱  timeout reached after ${ELAPSED}s"
        break
    fi

    TIME_FMT=$(date +%H:%M:%S)
    SIG=""
    LINE=""
    for T in "${COLLECTIONS[@]}"; do
        N=$(count_for "$T")
        SIG+="${N:-?},"
        LINE+="${T}=${N:-?} "
    done
    PEERS=$(curl -s "${URL}/api/v0/p2p/active-peers" | jq -c)
    SINCE_CHANGE=$((NOW - LAST_CHANGE_AT))
    printf "[%s] %s peers=%s  idle=%ss\n" "$TIME_FMT" "$LINE" "$PEERS" "$SINCE_CHANGE"

    if [[ "$SIG" != "$PREV_SIG" ]]; then
        LAST_CHANGE_AT=$NOW
        PREV_SIG="$SIG"
    elif (( SINCE_CHANGE >= STABLE_S )); then
        echo
        echo "✓ no row growth for ${STABLE_S}s — calling sync settled"
        break
    fi
    sleep 3
done

echo
echo "=== final counts ==="
for T in "${COLLECTIONS[@]}"; do
    N=$(count_for "$T")
    printf "  %-14s %s\n" "$T" "${N:-?}"
done
