#!/usr/bin/env bash
# For the kill -9 fail-safe test (CLAUDE.md): needs a genuinely installed app, not a build-dir binary.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
source "${REPO_ROOT}/scripts/build-config.sh"

SKIP_TESTS=false
for arg in "$@"; do
    case "$arg" in
        --skip-tests) SKIP_TESTS=true ;;
    esac
done

# --- Test

if [ "${SKIP_TESTS}" = false ]; then
    echo "==> Running tests..."
    "${REPO_ROOT}/test.sh"
    echo ""
fi

# --- Build

"${REPO_ROOT}/build.sh"

# --- Install & launch

BUNDLE="${REPO_ROOT}/.build/${APP_NAME}.app"

pkill -x "${APP_NAME}" 2>/dev/null && sleep 0.5 || true

echo "Installing to /Applications..."
rm -rf "/Applications/${APP_NAME}.app"
cp -R "${BUNDLE}" "/Applications/${APP_NAME}.app"

echo "Launching ${APP_NAME}..."
open "/Applications/${APP_NAME}.app"

echo "Done."
