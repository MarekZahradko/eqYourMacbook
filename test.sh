#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"

PRODUCT="eqYourMacbookTestRunner"

echo "==> Running unit tests..."
swift build --product "${PRODUCT}"

BIN="$(swift build --product "${PRODUCT}" --show-bin-path)/${PRODUCT}"
LOG="$(mktemp)"
trap 'rm -f "${LOG}"' EXIT

"${BIN}" 2>&1 | tee "${LOG}"
STATUS="${PIPESTATUS[0]}"

if [ "${STATUS}" -ne 0 ]; then
    echo ""
    echo "==> Failed test details:"
    # swift-testing prefixes each recorded issue/failing test with "✘"; the final
    # one-line run summary ("✘ Test run with N tests...") is the only one worth
    # dropping here, since it carries no location/expectation detail to review.
    grep "✘" "${LOG}" | grep -v "^✘ Test run with " || true
fi

exit "${STATUS}"
