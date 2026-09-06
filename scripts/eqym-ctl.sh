#!/usr/bin/env bash
# Builds (when stale) and runs eqym-ctl, the bench tool that drives and observes the
# installed app over its control channel. `scripts/eqym-ctl.sh` with no arguments prints
# the command list. Sources: scripts/eqym-ctl/ plus the app's own protocol file, compiled
# in verbatim so tool and app cannot disagree on a key.
#
#   scripts/eqym-ctl.sh status
#   scripts/eqym-ctl.sh latency         # ~35 s, automated, needs Microphone access for the terminal
#   scripts/eqym-ctl.sh watch           # then start a call; prints the exclusion window
#
# Reading the app log by hand: use /usr/bin/log explicitly — zsh has a `log` builtin that
# shadows it and prints nothing useful:
#   /usr/bin/log show --last 10m --predicate 'subsystem == "com.zdenekkops.eqyourmacbook"'
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_ROOT}/scripts/build-config.sh"
TOOL_DIR="${REPO_ROOT}/scripts/eqym-ctl"
BUILD_DIR="${REPO_ROOT}/.build/eqym-ctl"
MEASURE_DIR="${REPO_ROOT}/.build/measure"
BIN="${BUILD_DIR}/eqym-ctl"
PROTOCOL="${REPO_ROOT}/Sources/App/EQControlProtocol.swift"
mkdir -p "${BUILD_DIR}" "${MEASURE_DIR}"

stale=false
if [ ! -x "${BIN}" ]; then
    stale=true
else
    for src in "${TOOL_DIR}"/*.swift "${PROTOCOL}"; do
        if [ "${src}" -nt "${BIN}" ]; then stale=true; break; fi
    done
fi

if [ "${stale}" = true ]; then
    SDK_PATH=$(xcrun --show-sdk-path)
    echo "Compiling eqym-ctl…" >&2
    swiftc "${TOOL_DIR}"/*.swift "${PROTOCOL}" \
        -o "${BIN}" \
        -target "$(uname -m)-apple-macosx${DEPLOYMENT_TARGET}" \
        -sdk "${SDK_PATH}" \
        -swift-version 5 \
        -framework Foundation -framework CoreAudio -framework AVFoundation \
        -O
fi

case "${1:-}" in
    latency|watch)
        if [ $# -eq 1 ]; then exec "${BIN}" "$1" "${MEASURE_DIR}"; fi ;;
esac
exec "${BIN}" "$@"
