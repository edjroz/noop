#!/usr/bin/env bash
# Build DefraEmbed.xcframework from the Phase 1 Go module.
#
# Strategy: `go build -buildmode=c-shared` per arch (darwin/arm64 +
# darwin/amd64), `lipo` the two dylibs into one universal binary, hand-roll the
# `.framework` bundle, then `xcodebuild -create-xcframework` to wrap it.
#
# Output: Packages/DefraSync/DefraEmbed.xcframework/ (gitignored).
#
# Usage:
#   ./Tools/defradb-embed/build.sh
#
# First build: ~10 min (Go has to compile the full defradb dep tree).
# Subsequent builds: ~1–2 min (Go's cache handles most of it).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)"
EMBED_DIR="${REPO_ROOT}/Packages/DefraSync/defradb-embed"
OUT_DIR="${REPO_ROOT}/Packages/DefraSync/DefraEmbed.xcframework"

# Fast path: when nothing in the Go module is newer than the framework, skip the
# rebuild entirely. Lets us wire this as an Xcode pre-build script without paying
# the ~10s lipo+xcframework cost on every Cmd-B. Force with FORCE_REBUILD=1.
if [[ "${FORCE_REBUILD:-0}" != "1" && -f "${OUT_DIR}/Info.plist" ]]; then
    NEWEST=$(find "${EMBED_DIR}" -name '*.go' -o -name 'go.mod' -o -name 'go.sum' \
        | xargs -I {} stat -f '%m' {} 2>/dev/null | sort -nr | head -1)
    FW_MTIME=$(stat -f '%m' "${OUT_DIR}/Info.plist" 2>/dev/null || echo 0)
    if [[ -n "${NEWEST}" && "${NEWEST}" -le "${FW_MTIME}" ]]; then
        echo "→ DefraEmbed.xcframework is up to date (no Go sources newer than the framework) — skipping rebuild"
        echo "→ Force with FORCE_REBUILD=1 ${0##*/}"
        exit 0
    fi
fi

STAGE_DIR="$(mktemp -d -t defradb-embed-build.XXXXXX)"
trap 'rm -rf "${STAGE_DIR}"' EXIT

# The module needs Go >= 1.25.5 (see go.mod). Use whatever `go` is on PATH and
# ask the binary for its own GOROOT — hard-coding a Cellar path is what caused
# the "version 'go1.24.6' does not match go tool version 'go1.25.5'" wedge in
# Phase 1, since the path and the binary could drift apart. Override the binary
# with GO_BIN=/path/to/go if you need a specific toolchain.
GO_BIN="${GO_BIN:-go}"
if ! command -v "${GO_BIN}" >/dev/null 2>&1; then
    echo "❌ go not found on PATH. Install with: brew install go (or set GO_BIN=/path/to/go)" >&2
    exit 1
fi
GO_VERSION_FULL="$("${GO_BIN}" version | awk '{print $3}')"             # e.g. go1.26.4
GO_VERSION="${GO_VERSION_FULL#go}"                                       # 1.26.4
MIN_VERSION="1.25.5"
if [[ "$(printf '%s\n%s\n' "${MIN_VERSION}" "${GO_VERSION}" | sort -V | head -1)" != "${MIN_VERSION}" ]]; then
    echo "❌ Go ${GO_VERSION} is older than the required ${MIN_VERSION} (see go.mod)." >&2
    exit 1
fi
GOROOT="$("${GO_BIN}" env GOROOT)"
if [[ ! -d "${GOROOT}" ]]; then
    echo "❌ Resolved GOROOT does not exist: ${GOROOT}" >&2
    exit 1
fi
export GOROOT
echo "→ Go ${GO_VERSION} (GOROOT=${GOROOT})"

# CGo needs Clang from the host's macOS SDK. xcrun resolves it for us; we don't
# hard-code a path.
export CC="$(xcrun --find clang)"
export CGO_ENABLED=1
echo "→ CC=${CC}"

CSHARED_PKG="./cmd/cshared"

build_arch() {
    local arch="$1"           # arm64 | amd64
    local lipo_arch="$2"      # arm64 | x86_64
    local out_dylib="${STAGE_DIR}/libDefraEmbed_${lipo_arch}.dylib"

    echo "→ Building darwin/${arch} → ${out_dylib##*/}"
    GOOS=darwin GOARCH="${arch}" SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" \
        "${GO_BIN}" -C "${EMBED_DIR}" build \
            -buildmode=c-shared \
            -ldflags="-s -w" \
            -trimpath \
            -o "${out_dylib}" \
            "${CSHARED_PKG}"
}

build_arch arm64 arm64
build_arch amd64 x86_64

# Combine into one universal dylib. Header is identical between arches, keep one.
UNIVERSAL="${STAGE_DIR}/DefraEmbed"
lipo -create \
    "${STAGE_DIR}/libDefraEmbed_arm64.dylib" \
    "${STAGE_DIR}/libDefraEmbed_x86_64.dylib" \
    -output "${UNIVERSAL}"
echo "→ Universal dylib:"
lipo -info "${UNIVERSAL}"

# `cgo` emits libDefraEmbed_<arch>.h alongside each per-arch build. Pick the
# arm64 one; their contents are identical.
CGEN_HEADER="${STAGE_DIR}/libDefraEmbed_arm64.h"
if [[ ! -f "${CGEN_HEADER}" ]]; then
    echo "❌ Expected generated header at ${CGEN_HEADER}" >&2
    exit 1
fi

# Set the dylib's install name to a framework-relative path. Without this,
# anything linking the framework would record the staging dir's absolute path
# in its load commands.
install_name_tool -id "@rpath/DefraEmbed.framework/DefraEmbed" "${UNIVERSAL}"

# Strip Swift quarantine bits + adjust permissions.
chmod 0755 "${UNIVERSAL}"

# Hand-build DefraEmbed.framework with the macOS "versioned bundle" layout.
FRAMEWORK_DIR="${STAGE_DIR}/DefraEmbed.framework"
mkdir -p \
    "${FRAMEWORK_DIR}/Versions/A/Headers" \
    "${FRAMEWORK_DIR}/Versions/A/Modules" \
    "${FRAMEWORK_DIR}/Versions/A/Resources"

cp "${UNIVERSAL}"  "${FRAMEWORK_DIR}/Versions/A/DefraEmbed"
cp "${CGEN_HEADER}" "${FRAMEWORK_DIR}/Versions/A/Headers/DefraEmbed.h"
cp "${REPO_ROOT}/Tools/defradb-embed/module.modulemap.template" \
    "${FRAMEWORK_DIR}/Versions/A/Modules/module.modulemap"

cat > "${FRAMEWORK_DIR}/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>DefraEmbed</string>
    <key>CFBundleIdentifier</key><string>com.noopapp.DefraEmbed</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>DefraEmbed</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>1.0.0-defraembed-phase2</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>MinimumOSVersion</key><string>13.0</string>
    <key>NSPrincipalClass</key><string></string>
</dict>
</plist>
PLIST

# Standard macOS framework symlinks: Versions/Current → A, plus top-level
# symlinks that point into Versions/Current.
( cd "${FRAMEWORK_DIR}/Versions" && ln -sf A Current )
( cd "${FRAMEWORK_DIR}" \
    && ln -sf Versions/Current/DefraEmbed DefraEmbed \
    && ln -sf Versions/Current/Headers   Headers \
    && ln -sf Versions/Current/Modules   Modules \
    && ln -sf Versions/Current/Resources Resources )

# Wrap into an .xcframework. xcodebuild won't accept the framework if the dir
# already exists, so wipe the previous run first.
if [[ -d "${OUT_DIR}" ]]; then rm -rf "${OUT_DIR}"; fi
xcodebuild -create-xcframework \
    -framework "${FRAMEWORK_DIR}" \
    -output "${OUT_DIR}" >/dev/null

# Verification summary.
DYLIB_INSIDE="$(find "${OUT_DIR}" -type f -name DefraEmbed | head -n1)"
SIZE_HUMAN="$(du -sh "${OUT_DIR}" | awk '{print $1}')"
SHA256="$(shasum -a 256 "${DYLIB_INSIDE}" | awk '{print $1}')"

ARCHS_LIST="$(lipo -archs "${DYLIB_INSIDE}")"
SYMS_LIST="$(nm -gU --arch arm64 "${DYLIB_INSIDE}" 2>/dev/null | grep '_Defra' | awk '{print $3}' | sed 's/^_//' | sort | paste -sd, -)"
cat <<EOF

✅ DefraEmbed.xcframework built
   path:   ${OUT_DIR##${REPO_ROOT}/}
   size:   ${SIZE_HUMAN}
   sha256: ${SHA256}
   archs:  ${ARCHS_LIST}
   syms:   ${SYMS_LIST}
EOF
