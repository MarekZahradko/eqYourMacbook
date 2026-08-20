#!/usr/bin/env bash
# Output: build/dist/eqYourMacbook.zip (ad-hoc signed, see build.sh).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_ROOT}/scripts/build-config.sh"

DIST="${REPO_ROOT}/build/dist"

echo "==> Building (Release, ad-hoc signed)..."
"${REPO_ROOT}/build.sh" --release

APP="${REPO_ROOT}/.build/${APP_NAME}.app"
if [ ! -d "${APP}" ]; then
    echo "error: built app not found at ${APP}"
    exit 1
fi

echo "==> Packaging..."
rm -rf "${DIST}"
mkdir -p "${DIST}"
# ditto preserves bundle metadata and symlinks correctly (unlike zip).
ditto -c -k --sequesterRsrc --keepParent "${APP}" "${DIST}/${APP_NAME}.zip"

echo "Built:     ${APP}"
echo "Packaged:  ${DIST}/${APP_NAME}.zip"
