#!/bin/bash
# Runs the shared test suites (schemes BudgetCoreTests, MangoSyncTests and MangoUITests) on the iOS simulator,
# serially and without signing. Exits non-zero on any build error or test failure.
# IOS_SIM_DEVICE picks the simulator (default iPhone 17); LOG keeps the full xcodebuild log.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/package-workspace.sh
DEVICE="${IOS_SIM_DEVICE:-iPhone 17}"
OUT="${LOG:-$(mktemp -t test-core-ios)}"
[ -n "${LOG:-}" ] || trap 'rm -f "$OUT"' EXIT
# The shared suites: BudgetCore's, then MangoSync's (the CloudKit transport and key store, against fakes), then
# MangoUI's (the design system's money, fit and stacking rules and the wrap probe).
# Each scheme is a shared scheme under .swiftpm/xcode/xcshareddata/xcschemes (force-added; see .gitignore).
STATUS=0
for SCHEME in BudgetCoreTests MangoSyncTests MangoUITests; do
  if xcodebuild test -workspace "$(package_workspace)" -scheme "$SCHEME" \
      -destination "platform=iOS Simulator,name=$DEVICE" -parallel-testing-enabled NO \
      -derivedDataPath "${DERIVED_DATA:-${TMPDIR:-/tmp}/budgetcore-ios-test-dd}" \
      CODE_SIGNING_ALLOWED=NO >"$OUT" 2>&1; then
    echo "$SCHEME: $(grep -E "Executed [0-9]+ tests" "$OUT" | tail -1 | sed -E 's/^[[:space:]]+//')"
  else
    grep -E " error:|: error -|Test Case .* failed|crashed|Restarting after|Executed [0-9]+ tests, with|TEST FAILED|BUILD FAILED|Testing failed" "$OUT" \
      | grep -vE "Executed [0-9]+ tests, with 0 failures" | sort -u
    echo "$SCHEME: $(grep -E "Executed [0-9]+ tests" "$OUT" | tail -1 | sed -E 's/^[[:space:]]+//')"
    echo "$SCHEME FAILED on iOS" >&2
    STATUS=1
    # LOG keeps the failing suite's log.
    break
  fi
done
if [ "$STATUS" -eq 0 ]; then
  echo "iOS tests OK"
else
  echo "iOS tests FAILED" >&2
  exit 1
fi
