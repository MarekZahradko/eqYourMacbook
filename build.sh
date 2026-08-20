#!/usr/bin/env bash
# swiftc directly, no xcodebuild — Command Line Tools are enough, no Xcode.app.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
source "${REPO_ROOT}/scripts/build-config.sh"
SRC_DIR="${REPO_ROOT}/Sources"
RESOURCES_DIR="${REPO_ROOT}/Resources"

RELEASE=false
for arg in "$@"; do
    case "$arg" in
        --release) RELEASE=true ;;
    esac
done

BUILD_DIR="${REPO_ROOT}/.build"
BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${BUNDLE}/Contents"

# --- Prerequisites

if ! command -v swiftc &>/dev/null; then
    echo "Error: swiftc not found. Install Command Line Tools: xcode-select --install"
    exit 1
fi

SDK_PATH=$(xcrun --show-sdk-path 2>/dev/null || true)
if [ -z "${SDK_PATH}" ] || [ ! -d "${SDK_PATH}" ]; then
    echo "Error: macOS SDK not found. Install Command Line Tools: xcode-select --install"
    exit 1
fi

ARCH=$(uname -m)

# --- Clean & prepare

rm -rf "${BUNDLE}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"

# --- Compile

if [ "${RELEASE}" = true ]; then
    echo "Compiling ${APP_NAME} (${ARCH}, Swift ${SWIFT_VERSION}, Release)..."
    OPT_FLAGS="-O"
else
    echo "Compiling ${APP_NAME} (${ARCH}, Swift ${SWIFT_VERSION}, Debug)..."
    OPT_FLAGS="-Onone -D DEBUG"
fi

swiftc $(find "${SRC_DIR}" -name "*.swift") \
    -o "${CONTENTS}/MacOS/${APP_NAME}" \
    -target "${ARCH}-apple-macosx${DEPLOYMENT_TARGET}" \
    -sdk "${SDK_PATH}" \
    -swift-version "${SWIFT_VERSION}" \
    -default-isolation "${DEFAULT_ISOLATION}" \
    $(for f in ${UPCOMING_FEATURES}; do printf -- "-enable-upcoming-feature %s " "$f"; done) \
    -framework CoreAudio \
    -framework AudioToolbox \
    -framework Accelerate \
    -framework AppKit \
    -framework SwiftUI \
    -framework Combine \
    -framework ServiceManagement \
    ${OPT_FLAGS}

# --- Info.plist

# $(EXECUTABLE_NAME) is an Xcode build variable; nothing else substitutes it.
sed "s/\$(EXECUTABLE_NAME)/${APP_NAME}/" "${RESOURCES_DIR}/Info.plist" \
    > "${CONTENTS}/Info.plist"

# --- Code sign

# Required for AudioHardwareCreateProcessTap under Hardened Runtime (CLAUDE.md § Invariants).
codesign --force --sign - \
    --entitlements "${RESOURCES_DIR}/${APP_NAME}.entitlements" \
    --options runtime \
    "${BUNDLE}"

echo "Built: ${BUNDLE}"
