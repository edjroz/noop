#!/usr/bin/env bash
# Nuke everything Xcode + SwiftPM could have cached for this project, regenerate the .xcodeproj,
# and re-open it. Use when packages won't resolve, or when builds are mysteriously stale after a
# branch switch.
#
# Build reset only by default. Pass --data to ALSO wipe app state:
#   - my-whoop rows from the local SQLite store (the deviceId MockSeeder now writes
#     under — the dashboard reads this deviceId, so this is also where any real
#     WHOOP import would live; only safe to run while the experiment is mock-only).
#   - the entire DefraDB data dir (collections, p2p identity, replicators).
#   - UserDefaults for schema-hash and backfill-done flags (binary-path override is kept).
# Pass --no-build to skip the build reset (data wipe only).
# Pass --no-open to skip re-launching Xcode.
#
# This NEVER touches the vendored defradb binary or your source tree.

set -euo pipefail

DO_BUILD=1
DO_DATA=0
DO_OPEN=1
for arg in "$@"; do
    case "$arg" in
        --data) DO_DATA=1 ;;
        --no-build) DO_BUILD=0 ;;
        --no-open) DO_OPEN=0 ;;
        -h|--help)
            grep '^# ' "$0" | sed 's/^# //'
            exit 0 ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

if [[ "${DO_BUILD}" == 1 ]] && pgrep -x Xcode >/dev/null; then
    echo "⚠️  Xcode is running — quit it first (Cmd-Q), then re-run this script." >&2
    exit 1
fi

if [[ "${DO_DATA}" == 1 ]] && pgrep -x NOOP >/dev/null; then
    echo "⚠️  Strand/NOOP is running — quit it first (Cmd-Q) before wiping data." >&2
    exit 1
fi

if [[ "${DO_BUILD}" == 1 ]]; then
    echo "→ Removing generated Xcode project"
    rm -rf Strand.xcodeproj

    echo "→ Clearing SwiftPM global cache"
    rm -rf ~/Library/Caches/org.swift.swiftpm

    echo "→ Clearing DerivedData for this project"
    rm -rf ~/Library/Developer/Xcode/DerivedData/Strand-*

    echo "→ Wiping per-package .build / .swiftpm under Packages and Tools"
    find Packages Tools -type d \( -name .build -o -name .swiftpm \) -prune -exec rm -rf {} + 2>/dev/null || true

    echo "→ Regenerating Xcode project via xcodegen"
    if ! command -v xcodegen >/dev/null; then
        echo "❌ xcodegen not found. Install with: brew install xcodegen" >&2
        exit 1
    fi
    xcodegen generate
fi

if [[ "${DO_DATA}" == 1 ]]; then
    DB="${HOME}/Library/Application Support/OpenWhoop/whoop.sqlite"
    DEFRA_DIR="${HOME}/Library/Application Support/OpenWhoop/defra"

    if [[ -f "${DB}" ]]; then
        echo "→ Deleting my-whoop / mock-* rows from local SQLite store"
        # MockSeeder used to write under mock-<hostname-hash>; it now writes under my-whoop so
        # the dashboard actually shows the rows. Wipe both patterns so this script keeps working
        # for anyone on either old or new seeded data.
        #
        # The store runs in WAL mode, so deletes land in whoop.sqlite-wal until a checkpoint folds
        # them into the main file. We TRUNCATE-checkpoint and then remove the -wal/-shm sidecars so
        # a stale WAL can't make the wipe look like it didn't take. PRAGMAs and the count read-back
        # are in the same sqlite3 invocation so they observe the post-delete state.
        sqlite3 "${DB}" <<'SQL'
PRAGMA foreign_keys = ON;
DELETE FROM dailyMetric  WHERE deviceId = 'my-whoop' OR deviceId LIKE 'mock-%';
DELETE FROM sleepSession WHERE deviceId = 'my-whoop' OR deviceId LIKE 'mock-%';
DELETE FROM journal      WHERE deviceId = 'my-whoop' OR deviceId LIKE 'mock-%';
DELETE FROM workout      WHERE deviceId = 'my-whoop' OR deviceId LIKE 'mock-%';
DELETE FROM appleDaily   WHERE deviceId = 'my-whoop' OR deviceId LIKE 'mock-%';
DELETE FROM defra_outbox;
PRAGMA wal_checkpoint(TRUNCATE);
SQL
        rm -f "${DB}-wal" "${DB}-shm"

        # Read-back so an aborted/partial wipe can't masquerade as success.
        remaining=$(sqlite3 "${DB}" "
            SELECT COALESCE(SUM(n),0) FROM (
                SELECT COUNT(*) n FROM dailyMetric  WHERE deviceId='my-whoop' OR deviceId LIKE 'mock-%'
                UNION ALL SELECT COUNT(*) FROM sleepSession WHERE deviceId='my-whoop' OR deviceId LIKE 'mock-%'
                UNION ALL SELECT COUNT(*) FROM journal      WHERE deviceId='my-whoop' OR deviceId LIKE 'mock-%'
                UNION ALL SELECT COUNT(*) FROM workout      WHERE deviceId='my-whoop' OR deviceId LIKE 'mock-%'
                UNION ALL SELECT COUNT(*) FROM appleDaily   WHERE deviceId='my-whoop' OR deviceId LIKE 'mock-%'
                UNION ALL SELECT COUNT(*) FROM defra_outbox
            );")
        if [[ "${remaining}" == "0" ]]; then
            echo "  ✓ SQLite store cleared (0 mock rows remain)"
        else
            echo "  ❌ ${remaining} mock rows still present after wipe — is the app holding the DB?" >&2
            exit 1
        fi
    else
        echo "(no whoop.sqlite yet, skipping SQL wipe)"
    fi

    if [[ -d "${DEFRA_DIR}" ]]; then
        echo "→ Removing DefraDB data dir"
        rm -rf "${DEFRA_DIR}"
    fi

    echo "→ Clearing schema-hash and backfill-done UserDefaults"
    defaults delete com.noopapp.noop defra.schema.hash 2>/dev/null || true
    defaults delete com.noopapp.noop defra.backfill.done 2>/dev/null || true
fi

if [[ "${DO_BUILD}" == 1 && "${DO_OPEN}" == 1 ]]; then
    echo "→ Opening Strand.xcodeproj"
    open Strand.xcodeproj
fi

echo
echo "✅ Done."
if [[ "${DO_BUILD}" == 1 ]]; then
    cat <<'EOF'
In Xcode:
   1. Wait for "Resolving packages…" to finish in the status bar.
   2. Cmd-B to build, Cmd-R to run.

If packages still won't resolve, hit File → Packages → Reset Package Caches,
then File → Packages → Resolve Package Versions.
EOF
fi
