#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"

PRODUCT="eqYourMacbookTestRunner"

# App compilation gate. The SwiftPM test target EXCLUDES App/eqYourMacbookApp.swift (the
# @main entry) and is invoked differently from the shipping build (build.sh's swiftc with
# -default-isolation etc.), so `swift test` passing does NOT prove the app compiles — an
# ambiguous-type error in the app once shipped green here and only broke ./install.sh.
# build.sh --typecheck closes that: it compiles every source with the real app flags.
echo "==> Type-checking the app (build.sh flags — SwiftPM tests do not cover app compilation)..."
if ! "${REPO_ROOT}/build.sh" --typecheck; then
    echo "==> App does NOT compile — failing before tests. (Tests may still pass; they build a different target.)"
    exit 1
fi
echo ""

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
