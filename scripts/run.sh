#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

APP_DIR="$(xcodebuild \
    -project eqYourMacbook.xcodeproj \
    -scheme eqYourMacbook \
    -configuration Debug \
    -showBuildSettings 2>/dev/null \
    | awk '/BUILT_PRODUCTS_DIR/{print $3}')"

if [ -z "$APP_DIR" ]; then
    echo "error: could not find build output — run scripts/build.sh first"
    exit 1
fi

open "$APP_DIR/eqYourMacbook.app"
