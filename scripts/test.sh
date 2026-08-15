#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PRODUCT="eqYourMacbookTestRunner"

echo "==> Running unit tests..."
swift build --product "${PRODUCT}"
"$(swift build --product "${PRODUCT}" --show-bin-path)/${PRODUCT}"
