#!/usr/bin/env bash
# Build a Release .app and package it as a distributable zip.
# Prerequisites: brew install xcodegen
# Output: build/dist/eqYourMacbook.zip
#
# The Release configuration is ad-hoc signed (see project.yml). This is the
# proportionate choice for a personal-use app: no Apple Developer team,
# certificates, or notarization are required, and the build is reproducible
# both locally and in CI without secrets.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DERIVED="$REPO_ROOT/build/DerivedData"
DIST="$REPO_ROOT/build/dist"

echo "==> Generating Xcode project..."
xcodegen generate

echo "==> Building (Release, ad-hoc signed)..."
xcodebuild \
    -project eqYourMacbook.xcodeproj \
    -scheme eqYourMacbook \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    build

PRODUCTS_DIR="$(xcodebuild \
    -project eqYourMacbook.xcodeproj \
    -scheme eqYourMacbook \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    -showBuildSettings 2>/dev/null \
    | awk '$1 == "BUILT_PRODUCTS_DIR" {print $3}')"

APP="$PRODUCTS_DIR/eqYourMacbook.app"
if [ ! -d "$APP" ]; then
    echo "error: built app not found at $APP"
    exit 1
fi

echo "==> Packaging..."
rm -rf "$DIST"
mkdir -p "$DIST"
# ditto preserves bundle metadata and symlinks correctly (unlike zip).
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/eqYourMacbook.zip"

echo "Built:     $APP"
echo "Packaged:  $DIST/eqYourMacbook.zip"
