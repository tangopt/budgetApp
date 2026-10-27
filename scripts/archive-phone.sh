#!/bin/bash
# Archives the iPhone app (MangoPhone, Release, team-signed) and exports an .ipa for App Store Connect / TestFlight
# (record "Mango Household Budget", bundle ubberninja.mango.ios). Local files only, unless --upload.
#
#   scripts/archive-phone.sh             archive + export; prints the .ipa path and size
#   scripts/archive-phone.sh --upload    the same, then uploads with altool. Refused unless these are set:
#                                          MANGO_ASC_KEY_ID      App Store Connect API key id
#                                          MANGO_ASC_ISSUER_ID   its issuer id
#                                          MANGO_ASC_KEY_FILE    path to AuthKey_<id>.p8
#                                        (an Admin or App Manager key; the Developer-role key used for notarytool
#                                        may be refused by App Store Connect)
#   scripts/archive-phone.sh --self-test checks the guards and the plist without building (no signing, no network)
#
# The team comes from the uncommitted Config/Signing.local.xcconfig (here or in the main checkout); it is never
# printed or committed. Build number = number of commits on HEAD, so every upload increases. OUT picks the folder
# for the archive and export (default: $TMPDIR/mango-phone-archive).
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT="${OUT:-${TMPDIR:-/tmp}/mango-phone-archive}"
UPLOAD=0
SELFTEST=0
for a in "$@"; do
  case "$a" in
    --upload) UPLOAD=1 ;;
    --self-test) SELFTEST=1 ;;
    *) echo "usage: $0 [--upload] [--self-test]" >&2; exit 2 ;;
  esac
done

# Upload guard: checked first, before any build, so a refused upload costs nothing.
missing=()
for v in MANGO_ASC_KEY_ID MANGO_ASC_ISSUER_ID MANGO_ASC_KEY_FILE; do
  [ -n "${!v:-}" ] || missing+=("$v")
done
upload_guard() {
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "Upload refused: set ${missing[*]} (App Store Connect API key; see the header of scripts/archive-phone.sh)." >&2
    return 1
  fi
  if [ ! -f "$MANGO_ASC_KEY_FILE" ]; then
    echo "Upload refused: MANGO_ASC_KEY_FILE does not point to a file." >&2
    return 1
  fi
}

# The team: Signing.local.xcconfig in this checkout, else the main checkout's (worktrees don't have the ignored file).
find_local_xcconfig() {
  local common main
  if [ -f Config/Signing.local.xcconfig ]; then echo "$ROOT/Config/Signing.local.xcconfig"; return; fi
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  main="$(dirname "$common")"
  [ -f "$main/Config/Signing.local.xcconfig" ] && echo "$main/Config/Signing.local.xcconfig"
  return 0
}
LOCAL="$(find_local_xcconfig)"
TEAM=""
if [ -n "$LOCAL" ]; then
  TEAM="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]*\).*/\1/p' "$LOCAL" | head -1)"
fi

PLIST_SRC="Config/ExportOptions-TestFlight.plist"
make_export_plist() { # $1 = destination file; adds teamID without printing it
  cp "$PLIST_SRC" "$1" && /usr/libexec/PlistBuddy -c "Add :teamID string $TEAM" "$1"
}

if [ "$SELFTEST" = 1 ]; then
  fail=0
  plutil -lint "$PLIST_SRC" >/dev/null || { echo "FAIL plist invalid"; fail=1; }
  for k in method signingStyle destination uploadSymbols; do
    /usr/libexec/PlistBuddy -c "Print :$k" "$PLIST_SRC" >/dev/null 2>&1 || { echo "FAIL plist lacks $k"; fail=1; }
  done
  [ "$(/usr/libexec/PlistBuddy -c 'Print :method' "$PLIST_SRC")" = app-store-connect ] || { echo "FAIL method"; fail=1; }
  /usr/libexec/PlistBuddy -c 'Print :teamID' "$PLIST_SRC" >/dev/null 2>&1 && { echo "FAIL committed plist names a team"; fail=1; }
  # The guard refuses with no variables, and again with the key file missing.
  if env -u MANGO_ASC_KEY_ID -u MANGO_ASC_ISSUER_ID -u MANGO_ASC_KEY_FILE "$0" --upload 2>/dev/null; then
    echo "FAIL --upload without variables was not refused"; fail=1
  fi
  if MANGO_ASC_KEY_ID=x MANGO_ASC_ISSUER_ID=y MANGO_ASC_KEY_FILE=/nonexistent "$0" --upload 2>/dev/null; then
    echo "FAIL --upload with a missing key file was not refused"; fail=1
  fi
  [ -n "$TEAM" ] && echo "team found: yes" || echo "team found: no"
  [ "$fail" = 0 ] && echo "archive-phone self-test OK"
  exit "$fail"
fi

if [ "$UPLOAD" = 1 ]; then upload_guard || exit 1; fi

if [ -z "$TEAM" ]; then
  echo "TestFlight needs the team-signed configuration: put DEVELOPMENT_TEAM in Config/Signing.local.xcconfig." >&2
  exit 1
fi

BUILD_NUMBER="$(git rev-list --count HEAD)"
ARCHIVE="$OUT/Mango.xcarchive"
EXPORT="$OUT/export"
LOG="$OUT/xcodebuild.log"
rm -rf "$ARCHIVE" "$EXPORT"
mkdir -p "$OUT"

xcodegen generate >"$LOG" 2>&1 || { tail -20 "$LOG"; echo "Archive FAILED (xcodegen)" >&2; exit 1; }

scrub() { sed "s/$TEAM/<team>/g"; }
# With the App Store Connect key, Xcode can register new identifiers and App Groups (the widget extension) while signing.
AUTH=()
if [ -n "${MANGO_ASC_KEY_FILE:-}" ] && [ -f "${MANGO_ASC_KEY_FILE:-}" ]; then
  AUTH=(-authenticationKeyPath "$MANGO_ASC_KEY_FILE" -authenticationKeyID "$MANGO_ASC_KEY_ID" -authenticationKeyIssuerID "$MANGO_ASC_ISSUER_ID")
fi
echo "Archiving (build $BUILD_NUMBER)…"
if ! xcodebuild archive -project Mango.xcodeproj -scheme MangoPhone -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates "${AUTH[@]}" DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" >>"$LOG" 2>&1; then
  grep -E " error:|ARCHIVE FAILED|Provisioning|No signing|certificate" "$LOG" | sort -u | scrub | head -20
  echo "Archive FAILED (log: $LOG, contains the team id; do not share)" >&2
  exit 1
fi

EXPORT_PLIST="$OUT/ExportOptions.plist"
make_export_plist "$EXPORT_PLIST" || { echo "Export FAILED (plist)" >&2; exit 1; }
echo "Exporting…"
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist "$EXPORT_PLIST" -allowProvisioningUpdates "${AUTH[@]}" >>"$LOG" 2>&1; then
  grep -E " error:|EXPORT FAILED|Provisioning|No signing|certificate|profile" "$LOG" | sort -u | scrub | head -20
  echo "Export FAILED (log: $LOG, contains the team id; do not share)" >&2
  exit 1
fi

IPA="$EXPORT/Mango.ipa"
[ -f "$IPA" ] || { echo "Export finished but $IPA is missing" >&2; exit 1; }
echo "$IPA"
echo "Size: $(du -h "$IPA" | cut -f1)  Build: $BUILD_NUMBER"

if [ "$UPLOAD" = 1 ]; then
  echo "Uploading to App Store Connect…"
  API_PRIVATE_KEYS_DIR="$(dirname "$MANGO_ASC_KEY_FILE")" \
    xcrun altool --upload-app -t ios -f "$IPA" --apiKey "$MANGO_ASC_KEY_ID" --apiIssuer "$MANGO_ASC_ISSUER_ID" || exit 1
  echo "Upload finished"
fi
