#!/bin/bash
# Builds the BudgetCore and MangoSync libraries for iOS (no signing). Exits non-zero on any error.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/package-workspace.sh
OUT="$(mktemp -t build-core-ios)"
trap 'rm -f "$OUT"' EXIT
# BudgetCore, then MangoSync (the CloudKit transport and key store both apps share).
for SCHEME in BudgetCore MangoSync; do
  if xcodebuild -workspace "$(package_workspace)" -scheme "$SCHEME" -destination 'generic/platform=iOS' \
      -derivedDataPath "${DERIVED_DATA:-${TMPDIR:-/tmp}/budgetcore-ios-dd}" \
      CODE_SIGNING_ALLOWED=NO build >"$OUT" 2>&1; then
    echo "iOS build OK ($SCHEME)"
  else
    grep -E " error:|BUILD FAILED" "$OUT" | sort -u
    echo "iOS build FAILED ($SCHEME)" >&2
    exit 1
  fi
done
