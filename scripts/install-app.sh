#!/bin/zsh
# Builds Mango in Release and installs it to /Applications, so it runs like any other app.
# Re-run after pulling new changes to update the installed copy. Your data stays where it is
# (~/Library/Application Support/Budget), shared by every copy of the app.
#
# With Config/Signing.local.xcconfig (build step 0) the app is signed with your team as a Developer ID
# app (Touch ID's Keychain item and iCloud need that signature). That is enough for this Mac: a locally
# built app isn't quarantined, so Gatekeeper never asks for notarisation.
#   scripts/install-app.sh              Developer ID, not notarised, for this Mac's architecture only.
#                                       Builds incrementally: seconds when little changed.
#   scripts/install-app.sh --notarise   universal archive, notarised by Apple and stapled: for another Mac
#                                       (several minutes: an archive recompiles everything)
#   scripts/install-app.sh --output DIR builds and signs as above but leaves Mango.app in DIR instead of
#                                       installing it: /Applications and LaunchServices are not touched.
# Notarising needs a notarytool keychain profile, by default "mango-notary" (NOTARY_PROFILE overrides
# it), and must run in a session that can read the login keychain. See
# docs/superpowers/plans/2026-10-22-step0-developer-setup.md. Without the signing file it builds as
# before: signed to run locally on this Mac only.
set -euo pipefail

usage() { echo "Usage: scripts/install-app.sh [--notarise] [--output DIR]" >&2; exit 2; }
NOTARISE=0
OUTPUT=""
while (( $# )); do
    case "$1" in
        --notarise|--notarize) NOTARISE=1 ;;
        --output) (( $# >= 2 )) || usage; OUTPUT="$2"; shift ;;
        *) usage ;;
    esac
    shift
done
if [[ -n "$OUTPUT" ]]; then
    mkdir -p "$OUTPUT"
    OUTPUT="$(cd "$OUTPUT" && pwd -P)"
    [[ "$OUTPUT" != /Applications ]] || { echo "--output is for a folder other than /Applications." >&2; exit 2; }
fi

cd "$(dirname "$0")/.."
# Xcode's build cache is kept between runs (outside ~/Documents, which iCloud tags with attributes
# that break code signing), so only what changed is rebuilt. Archives and exports are temporary.
CACHE_DIR="$HOME/Library/Caches/Mango-install"
mkdir -p "$CACHE_DIR"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

# Only the Mac app counts: the iPhone simulator's Mango is also a process named "Mango".
if [[ -z "$OUTPUT" ]] && { pgrep -f '/Mango\.app/Contents/MacOS/Mango$' >/dev/null || pgrep -f '/Budget\.app/Contents/MacOS/Budget$' >/dev/null; }; then
    echo "Quit Mango first, then run this again." >&2
    exit 1
fi

xcodegen generate

SIGNING=Config/Signing.local.xcconfig
TEAM=""
[[ -f "$SIGNING" ]] && TEAM="$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' "$SIGNING" | tr -d '[:space:]')"

# Signs an archive's app as Developer ID, the way Xcode's Organizer does: the right provisioning
# profile (fetched or renewed if needed), the entitlements resolved for distribution, hardened runtime.
export_developer_id() {
    cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>$TEAM</string>
</dict>
</plist>
PLIST
    xcodebuild -exportArchive -archivePath "$BUILD_DIR/Mango.xcarchive" \
        -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" -exportPath "$BUILD_DIR/export" \
        -allowProvisioningUpdates | grep -E "error:|EXPORT" || true
    APP="$BUILD_DIR/export/Mango.app"
    [[ -x "$APP/Contents/MacOS/Mango" ]] || { echo "Export failed." >&2; exit 1; }
}

if [[ -n "$TEAM" ]] && (( NOTARISE )); then
    # For another Mac: a universal archive (x86_64 and arm64). Archiving always recompiles everything.
    NOTARY_PROFILE="${NOTARY_PROFILE:-mango-notary}"
    xcodebuild -project Mango.xcodeproj -scheme Mango -configuration Release \
        -destination 'generic/platform=macOS' -derivedDataPath "$CACHE_DIR/team" \
        -archivePath "$BUILD_DIR/Mango.xcarchive" -allowProvisioningUpdates archive \
        | grep -E "error:|warning:|ARCHIVE" | grep -v appintents || true
    [[ -d "$BUILD_DIR/Mango.xcarchive" ]] || { echo "Archive failed." >&2; exit 1; }
    export_developer_id

    echo "Notarising (usually a few minutes)…"
    ditto -c -k --keepParent "$APP" "$BUILD_DIR/Mango.zip"
    xcrun notarytool submit "$BUILD_DIR/Mango.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
elif [[ -n "$TEAM" ]]; then
    # For this Mac: an incremental Release build for this Mac's architecture only, into the kept cache
    # (an archive would recompile everything, both architectures, every time). It comes out signed
    # for development; it is then wrapped as an archive and exported exactly as the --notarise path does.
    # Optimised file by file rather than whole-module: Xcode compiles packages whole-module in Release
    # (their -Owholemodule), so one BudgetCore change rebuilt all of BudgetCore (about 3-4 min). File by
    # file it is seconds, for about 7% slower code (TaxFigures.snapshot, measured 2026-10-25).
    ARCH="$(uname -m)"
    # The cache keeps the previous build's app, so its presence proves nothing: check xcodebuild itself.
    BUILD_OK=1
    xcodebuild -project Mango.xcodeproj -scheme Mango -configuration Release \
        -destination "platform=macOS,arch=$ARCH" -derivedDataPath "$CACHE_DIR/team" \
        -allowProvisioningUpdates ARCHS="$ARCH" ONLY_ACTIVE_ARCH=YES \
        SWIFT_COMPILATION_MODE=singlefile SWIFT_OPTIMIZATION_LEVEL=-O build \
        > "$BUILD_DIR/build.log" 2>&1 || BUILD_OK=0
    grep -E "error:|warning:|BUILD" "$BUILD_DIR/build.log" | grep -v appintents || true
    (( BUILD_OK )) || { echo "Build failed." >&2; exit 1; }
    BUILT="$CACHE_DIR/team/Build/Products/Release/Mango.app"
    [[ -x "$BUILT/Contents/MacOS/Mango" ]] || { echo "Build failed." >&2; exit 1; }

    # The archive Xcode's export reads: the app under Products/Applications and an Info.plist naming it.
    ARCHIVE="$BUILD_DIR/Mango.xcarchive"
    mkdir -p "$ARCHIVE/Products/Applications"
    ditto "$BUILT" "$ARCHIVE/Products/Applications/Mango.app"
    # Strip symbols the way an archive does (the export re-signs afterwards).
    xcrun strip -D "$ARCHIVE/Products/Applications/Mango.app/Contents/MacOS/Mango"
    INFO="$BUILT/Contents/Info.plist"
    plist() { /usr/libexec/PlistBuddy -c "$1" "$ARCHIVE/Info.plist" >/dev/null; }
    plist "Add :ArchiveVersion integer 2"
    plist "Add :CreationDate date $(date '+%a %b %d %T %Z %Y')"
    plist "Add :Name string Mango"
    plist "Add :SchemeName string Mango"
    plist "Add :ApplicationProperties dict"
    plist "Add :ApplicationProperties:ApplicationPath string Applications/Mango.app"
    plist "Add :ApplicationProperties:Architectures array"
    plist "Add :ApplicationProperties:Architectures:0 string $ARCH"
    plist "Add :ApplicationProperties:CFBundleIdentifier string $(defaults read "$INFO" CFBundleIdentifier)"
    plist "Add :ApplicationProperties:CFBundleShortVersionString string $(defaults read "$INFO" CFBundleShortVersionString)"
    plist "Add :ApplicationProperties:CFBundleVersion string $(defaults read "$INFO" CFBundleVersion)"
    plist "Add :ApplicationProperties:SigningIdentity string $(codesign -dvv "$BUILT" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
    plist "Add :ApplicationProperties:Team string $TEAM"
    export_developer_id
else
    xcodebuild -project Mango.xcodeproj -scheme Mango -configuration Release \
        -destination 'platform=macOS' -derivedDataPath "$CACHE_DIR/local" build \
        | grep -E "error:|warning:|BUILD" | grep -v appintents || true
    APP="$CACHE_DIR/local/Build/Products/Release/Mango.app"
    [[ -x "$APP/Contents/MacOS/Mango" ]] || { echo "Build failed." >&2; exit 1; }
fi

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Keep the build folders' copies out of Spotlight, Launchpad and Open With.
for built in "$CACHE_DIR"/**/Mango.app(N); do "$LSREGISTER" -u "$built" 2>/dev/null || true; done

if [[ -n "$OUTPUT" ]]; then
    rm -rf "$OUTPUT/Mango.app"
    ditto "$APP" "$OUTPUT/Mango.app"
    "$LSREGISTER" -u "$OUTPUT/Mango.app" 2>/dev/null || true
    echo "Built $OUTPUT/Mango.app (not installed)"
    exit 0
fi

rm -rf /Applications/Mango.app
ditto "$APP" /Applications/Mango.app
[[ -x /Applications/Mango.app/Contents/MacOS/Mango ]] || { echo "Install failed." >&2; exit 1; }

# The app used to be called Budget (renamed Mango): now that Mango is in place, remove the old copy
# once and unregister it so Spotlight and Launchpad offer only Mango. Nothing else in /Applications
# is touched.
if [[ -d /Applications/Budget.app ]]; then
    "$LSREGISTER" -u /Applications/Budget.app 2>/dev/null || true
    rm -rf /Applications/Budget.app
    echo "Removed the old /Applications/Budget.app"
fi

# Point macOS at the installed copy (icon, Spotlight, Open With), not a build folder.
"$LSREGISTER" -u "$APP" 2>/dev/null || true

# Remove Xcode's own builds of the app so Spotlight and Launchpad only offer the installed one.
# Xcode rebuilds them the next time you run from Xcode (only the .app is removed, not the cache).
for old in ~/Library/Developer/Xcode/DerivedData/Mango-*/Build/Products/*/Mango.app(N) ~/Library/Developer/Xcode/DerivedData/Budget-*/Build/Products/*/Budget.app(N); do
    "$LSREGISTER" -u "$old" 2>/dev/null || true
    rm -rf "$old"
    echo "Removed Xcode build: $old"
done

"$LSREGISTER" -f /Applications/Mango.app

if [[ -n "$TEAM" ]] && (( NOTARISE )); then
    # Gatekeeper's verdict on the installed copy: expect "accepted, source=Notarized Developer ID".
    spctl --assess --type execute -vv /Applications/Mango.app 2>&1 || true
fi

echo "Installed /Applications/Mango.app"
