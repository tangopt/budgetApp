#!/bin/bash
# Builds the iPhone app (target MangoPhone) for the iOS simulator, unsigned. Regenerates Mango.xcodeproj first
# (XcodeGen), so the build always matches project.yml. Prints "Phone build OK" and the app's path; exits non-zero
# on any error. DERIVED_DATA picks the derived-data folder; CONFIGURATION picks Debug (default) or Release.
set -uo pipefail
cd "$(dirname "$0")/.."
DD="${DERIVED_DATA:-${TMPDIR:-/tmp}/mango-phone-dd}"
CONFIG="${CONFIGURATION:-Debug}"
OUT="$(mktemp -t build-phone)"
trap 'rm -f "$OUT"' EXIT
if ! xcodegen generate >"$OUT" 2>&1; then
  cat "$OUT"
  echo "Phone build FAILED (xcodegen)" >&2
  exit 1
fi
if xcodebuild -project Mango.xcodeproj -scheme MangoPhone -configuration "$CONFIG" \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD" \
    CODE_SIGNING_ALLOWED=NO build >"$OUT" 2>&1; then
  echo "$DD/Build/Products/$CONFIG-iphonesimulator/Mango.app"
  echo "Phone build OK"
else
  grep -E " error:|BUILD FAILED" "$OUT" | sort -u
  echo "Phone build FAILED" >&2
  exit 1
fi
