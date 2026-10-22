#!/bin/zsh
# Builds Mango in Release and installs it to /Applications, so it runs like any other app.
# Re-run after pulling new changes to update the installed copy. Your data stays where it is
# (~/Library/Application Support/Budget), shared by every copy of the app.
#
# With Config/Signing.local.xcconfig (build step 0) the app is archived with your team and exported as
# a Developer ID app (Touch ID's Keychain item and iCloud need that signature). That is enough for this
# Mac: a locally built app isn't quarantined, so Gatekeeper never asks for notarisation.
#   scripts/install-app.sh              Developer ID, not notarised: for this Mac (a minute or two)
#   scripts/install-app.sh --notarise   also notarised by Apple and stapled: for another Mac
# Notarising needs a notarytool keychain profile, by default "mango-notary" (NOTARY_PROFILE overrides
# it), and must run in a session that can read the login keychain. See
# docs/superpowers/plans/2026-10-22-step0-developer-setup.md. Without the signing file it builds as
# before: signed to run locally on this Mac only.
set -euo pipefail

NOTARISE=0
for arg in "$@"; do
    case "$arg" in
        --notarise|--notarize) NOTARISE=1 ;;
        *) echo "Usage: scripts/install-app.sh [--notarise]" >&2; exit 2 ;;
    esac
done

cd "$(dirname "$0")/.."
# Xcode's build cache is kept between runs (outside ~/Documents, which iCloud tags with attributes
# that break code signing), so only what changed is rebuilt. Archives and exports are temporary.
CACHE_DIR="$HOME/Library/Caches/Mango-install"
mkdir -p "$CACHE_DIR"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

if pgrep -x Mango >/dev/null || pgrep -x Budget >/dev/null; then
    echo "Quit Mango first, then run this again." >&2
    exit 1
fi

xcodegen generate

SIGNING=Config/Signing.local.xcconfig
TEAM=""
[[ -f "$SIGNING" ]] && TEAM="$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' "$SIGNING" | tr -d '[:space:]')"

if [[ -n "$TEAM" ]]; then
    NOTARY_PROFILE="${NOTARY_PROFILE:-mango-notary}"
    xcodebuild -project Mango.xcodeproj -scheme Mango -configuration Release \
        -destination 'generic/platform=macOS' -derivedDataPath "$CACHE_DIR/team" \
        -archivePath "$BUILD_DIR/Mango.xcarchive" -allowProvisioningUpdates archive \
        | grep -E "error:|warning:|ARCHIVE" | grep -v appintents || true
    [[ -d "$BUILD_DIR/Mango.xcarchive" ]] || { echo "Archive failed." >&2; exit 1; }

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

    if (( NOTARISE )); then
        echo "Notarising (usually a few minutes)…"
        ditto -c -k --keepParent "$APP" "$BUILD_DIR/Mango.zip"
        xcrun notarytool submit "$BUILD_DIR/Mango.zip" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$APP"
    fi
else
    xcodebuild -project Mango.xcodeproj -scheme Mango -configuration Release \
        -destination 'platform=macOS' -derivedDataPath "$CACHE_DIR/local" build \
        | grep -E "error:|warning:|BUILD" | grep -v appintents || true
    APP="$CACHE_DIR/local/Build/Products/Release/Mango.app"
    [[ -x "$APP/Contents/MacOS/Mango" ]] || { echo "Build failed." >&2; exit 1; }
fi

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

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
for built in "$CACHE_DIR"/**/Mango.app(N); do "$LSREGISTER" -u "$built" 2>/dev/null || true; done

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
