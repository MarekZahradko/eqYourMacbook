#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
source "${REPO_ROOT}/scripts/build-config.sh"

BUNDLE="${REPO_ROOT}/.build/${APP_NAME}.app"

if [ ! -d "${BUNDLE}" ]; then
    echo "error: ${BUNDLE} not found — run ./build.sh first"
    exit 1
fi

open "${BUNDLE}"
