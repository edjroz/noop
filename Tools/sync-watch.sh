#!/usr/bin/env bash
# Watch defradb row counts climb on this Mac. Use after `sync-replicate-to.sh` was run on
# the master Mac. Reports per-collection counts + active-peer list every 3s.
#
# Exits when row counts stop changing for 3 consecutive cycles, or after the timeout.
#
# Usage:
#   ./Tools/sync-watch.sh            # 60s default
#   ./Tools/sync-watch.sh 180        # custom timeout in seconds

set -uo pipefail

TIMEOUT_S="${1:-60}"
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
STABLE=0

echo "Watching for up to ${TIMEOUT_S}s. Exits when counts hold steady for 3 cycles."
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
    printf "[%s] %s peers=%s\n" "$TIME_FMT" "$LINE" "$PEERS"

    if [[ "$SIG" == "$PREV_SIG" ]]; then
        STABLE=$(( STABLE + 1 ))
        if (( STABLE >= 3 )); then
            echo
            echo "✓ counts stable for 3 cycles — sync settled"
            break
        fi
    else
        STABLE=0
    fi
    PREV_SIG="$SIG"
    sleep 3
done

echo
echo "=== final counts ==="
for T in "${COLLECTIONS[@]}"; do
    N=$(count_for "$T")
    printf "  %-14s %s\n" "$T" "${N:-?}"
done
