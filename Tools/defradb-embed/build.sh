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

# Toolchain selection. Override with GO_BIN=/path/to/go.
#
# Without an override, prefer Homebrew's go@1.25 keg if present. DefraDB v1.0.0-rc1
# locks bytedance/sonic at v1.14.2, and that version reads Go runtime internals
# directly — specifically a symbol called `GoMapIterator` that was restructured in
# Go 1.26. Building defradb's dep tree with Go >= 1.26 currently fails with
#   undefined: GoMapIterator
# in internal/rt/stubs.go. Pin to Go 1.25.x until defradb ships a release that bumps
# sonic past that restructure.
if [[ -z "${GO_BIN:-}" ]]; then
    if [[ -x /opt/homebrew/opt/go@1.25/bin/go ]]; then
        GO_BIN=/opt/homebrew/opt/go@1.25/bin/go
    else
        GO_BIN=go
    fi
fi

if ! command -v "${GO_BIN}" >/dev/null 2>&1; then
    echo "❌ Go not found at '${GO_BIN}'." >&2
    echo "   Install Go 1.25.x:  brew install go@1.25" >&2
    echo "   Or set GO_BIN=/path/to/go if you have a manual install." >&2
    exit 1
fi

GO_VERSION_FULL="$("${GO_BIN}" version | awk '{print $3}')"             # e.g. go1.25.5
GO_VERSION="${GO_VERSION_FULL#go}"                                       # 1.25.5
MIN_VERSION="1.25.5"
MAX_EXCLUSIVE="1.26.0"

# True iff $1 < $2 by version sort (and not equal).
ver_lt() {
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" && "$1" != "$2" ]]
}

if ver_lt "${GO_VERSION}" "${MIN_VERSION}"; then
    echo "❌ Go ${GO_VERSION} is older than the required ${MIN_VERSION} (see defradb-embed/go.mod)." >&2
    echo "   brew install go@1.25 — then re-run." >&2
    exit 1
fi

if ! ver_lt "${GO_VERSION}" "${MAX_EXCLUSIVE}"; then
    cat >&2 <<EOF
❌ Go ${GO_VERSION} is too new for DefraDB v1.0.0-rc1's transitive deps.

   bytedance/sonic v1.14.2 (pulled in by defradb) reads Go runtime internals and
   references an undefined GoMapIterator symbol against Go >= 1.26. Use Go 1.25.x
   until defradb ships a release with a sonic bump.

       brew install go@1.25
       (then either let this script auto-discover it, or set GO_BIN explicitly:)
       GO_BIN=/opt/homebrew/opt/go@1.25/bin/go ${0##*/}
EOF
    exit 1
fi

GOROOT="$("${GO_BIN}" env GOROOT)"
if [[ ! -d "${GOROOT}" ]]; then
    echo "❌ Resolved GOROOT does not exist: ${GOROOT}" >&2
    exit 1
fi
export GOROOT
echo "→ Go ${GO_VERSION} (GOROOT=${GOROOT}, GO_BIN=${GO_BIN})"

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
