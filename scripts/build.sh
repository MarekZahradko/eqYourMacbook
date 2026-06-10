#!/usr/bin/env bash
# Prerequisites: brew install xcodegen
# Run from the repo root on the Mac.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> Generating Xcode project..."
xcodegen generate

echo "==> Building (Debug)..."
xcodebuild \
    -project eqYourMacbook.xcodeproj \
    -scheme eqYourMacbook \
    -configuration Debug \
    build
