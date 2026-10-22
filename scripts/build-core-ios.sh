#!/bin/bash
# Builds the BudgetCore library for iOS (no signing). Exits non-zero on any error.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/package-workspace.sh
OUT="$(mktemp -t build-core-ios)"
trap 'rm -f "$OUT"' EXIT
if xcodebuild -workspace "$(package_workspace)" -scheme BudgetCore -destination 'generic/platform=iOS' \
    -derivedDataPath "${DERIVED_DATA:-${TMPDIR:-/tmp}/budgetcore-ios-dd}" \
    CODE_SIGNING_ALLOWED=NO build >"$OUT" 2>&1; then
  echo "iOS build OK"
else
  grep -E " error:|BUILD FAILED" "$OUT" | sort -u
  echo "iOS build FAILED" >&2
  exit 1
fi
