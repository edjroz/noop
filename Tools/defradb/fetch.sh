#!/usr/bin/env bash
# Fetch the pinned DefraDB sidecar binary for the DefraSync experiment.
#
# Runs idempotently — re-running when the binary is already present and matches the expected
# SHA-256 is a no-op. Designed so both the desktop and laptop land on bit-identical binaries,
# which matters because we sync schema state across them.
#
# Usage:
#   ./Tools/defradb/fetch.sh
#
# After this, Strand picks the binary up via SyncPaths.defraBinaryURL().

set -euo pipefail

VERSION="v1.0.0-rc1"
ASSET="defradb_1.0.0-rc1_darwin_arm64"
EXPECTED_SHA256="473222fa27973937a262105904b7674d7bf60ee5582f3ae20664a1cf6406f2fb"
URL="https://github.com/sourcenetwork/defradb/releases/download/${VERSION}/${ASSET}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_PATH="${SCRIPT_DIR}/defradb-darwin-arm64"

verify_sha256() {
    local path="$1"
    local actual
    actual="$(shasum -a 256 "${path}" | awk '{print $1}')"
    [[ "${actual}" == "${EXPECTED_SHA256}" ]]
}

if [[ -f "${OUT_PATH}" ]] && verify_sha256 "${OUT_PATH}"; then
    echo "defradb ${VERSION} already present at ${OUT_PATH}"
    exit 0
fi

ARCH="$(uname -m)"
if [[ "${ARCH}" != "arm64" ]]; then
    echo "⚠️  This Mac is ${ARCH}. DefraDB ${VERSION} only ships a darwin_arm64 binary." >&2
    echo "    Options: run under Rosetta, or build from source at https://github.com/sourcenetwork/defradb" >&2
    exit 1
fi

echo "Downloading defradb ${VERSION} (${ASSET}, ~165 MB)…"
curl -fSL -o "${OUT_PATH}" "${URL}"

if ! verify_sha256 "${OUT_PATH}"; then
    actual="$(shasum -a 256 "${OUT_PATH}" | awk '{print $1}')"
    echo "❌ Checksum mismatch." >&2
    echo "   expected ${EXPECTED_SHA256}" >&2
    echo "   actual   ${actual}" >&2
    rm -f "${OUT_PATH}"
    exit 1
fi

chmod +x "${OUT_PATH}"
echo "✅ Vendored defradb ${VERSION} → ${OUT_PATH}"
