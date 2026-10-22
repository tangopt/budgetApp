#!/bin/bash
# Runs the shared BudgetCore test suite (scheme BudgetCoreTests) on the iOS simulator,
# serially and without signing. Exits non-zero on any build error or test failure.
# IOS_SIM_DEVICE picks the simulator (default iPhone 17); LOG keeps the full xcodebuild log.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/package-workspace.sh
DEVICE="${IOS_SIM_DEVICE:-iPhone 17}"
OUT="${LOG:-$(mktemp -t test-core-ios)}"
[ -n "${LOG:-}" ] || trap 'rm -f "$OUT"' EXIT
if xcodebuild test -workspace "$(package_workspace)" -scheme BudgetCoreTests \
    -destination "platform=iOS Simulator,name=$DEVICE" -parallel-testing-enabled NO \
    -derivedDataPath "${DERIVED_DATA:-${TMPDIR:-/tmp}/budgetcore-ios-test-dd}" \
    CODE_SIGNING_ALLOWED=NO >"$OUT" 2>&1; then
  grep -E "Executed [0-9]+ tests" "$OUT" | tail -1
  echo "iOS tests OK"
else
  grep -E " error:|: error -|Test Case .* failed|crashed|Restarting after|Executed [0-9]+ tests, with|TEST FAILED|BUILD FAILED|Testing failed" "$OUT" \
    | grep -vE "Executed [0-9]+ tests, with 0 failures" | sort -u
  grep -E "Executed [0-9]+ tests" "$OUT" | tail -1
  echo "iOS tests FAILED" >&2
  exit 1
fi
