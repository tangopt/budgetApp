#!/bin/zsh
# Builds Budget in Release and installs it to /Applications, so it runs like any other app.
# Re-run after pulling new changes to update the installed copy. Your data stays where it is
# (~/Library/Application Support/Budget), shared by every copy of the app.
#
# With Config/Signing.local.xcconfig (build step 0) the app is archived with your team, exported as a
# Developer ID app, notarised by Apple and stapled, so it runs anywhere with no expiry. It needs a
# notarytool keychain profile, by default "mango-notary" (NOTARY_PROFILE overrides it); see
# docs/superpowers/plans/2026-10-22-step0-developer-setup.md. Without that file it builds as before:
# signed to run locally on this Mac only.
set -euo pipefail

cd "$(dirname "$0")/.."
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

if pgrep -x Budget >/dev/null; then
    echo "Quit Budget first, then run this again." >&2
    exit 1
fi

xcodegen generate

SIGNING=Config/Signing.local.xcconfig
TEAM=""
[[ -f "$SIGNING" ]] && TEAM="$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' "$SIGNING" | tr -d '[:space:]')"

if [[ -n "$TEAM" ]]; then
    NOTARY_PROFILE="${NOTARY_PROFILE:-mango-notary}"
    xcodebuild -project Budget.xcodeproj -scheme Budget -configuration Release \
        -destination 'generic/platform=macOS' -derivedDataPath "$BUILD_DIR/dd" \
        -archivePath "$BUILD_DIR/Budget.xcarchive" -allowProvisioningUpdates archive \
        | grep -E "error:|warning:|ARCHIVE" | grep -v appintents || true
    [[ -d "$BUILD_DIR/Budget.xcarchive" ]] || { echo "Archive failed." >&2; exit 1; }

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
    xcodebuild -exportArchive -archivePath "$BUILD_DIR/Budget.xcarchive" \
        -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" -exportPath "$BUILD_DIR/export" \
        -allowProvisioningUpdates | grep -E "error:|EXPORT" || true
    APP="$BUILD_DIR/export/Budget.app"
    [[ -x "$APP/Contents/MacOS/Budget" ]] || { echo "Export failed." >&2; exit 1; }

    echo "Notarising (usually a few minutes)…"
    ditto -c -k --keepParent "$APP" "$BUILD_DIR/Budget.zip"
    xcrun notarytool submit "$BUILD_DIR/Budget.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
else
    xcodebuild -project Budget.xcodeproj -scheme Budget -configuration Release \
        -destination 'platform=macOS' -derivedDataPath "$BUILD_DIR" build \
        | grep -E "error:|warning:|BUILD" | grep -v appintents || true
    APP="$BUILD_DIR/Build/Products/Release/Budget.app"
    [[ -x "$APP/Contents/MacOS/Budget" ]] || { echo "Build failed." >&2; exit 1; }
fi

rm -rf /Applications/Budget.app
ditto "$APP" /Applications/Budget.app

# Point macOS at the installed copy (icon, Spotlight, Open With), not a build folder.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$APP" 2>/dev/null || true

# Remove Xcode's own builds of the app so Spotlight and Launchpad only offer the installed one.
# Xcode rebuilds them the next time you run from Xcode (only the .app is removed, not the cache).
for old in ~/Library/Developer/Xcode/DerivedData/Budget-*/Build/Products/*/Budget.app(N); do
    "$LSREGISTER" -u "$old" 2>/dev/null || true
    rm -rf "$old"
    echo "Removed Xcode build: $old"
done

"$LSREGISTER" -f /Applications/Budget.app

if [[ -n "$TEAM" ]]; then
    # Gatekeeper's verdict on the installed copy: expect "accepted, source=Notarized Developer ID".
    spctl --assess --type execute -vv /Applications/Budget.app 2>&1 || true
fi

echo "Installed /Applications/Budget.app"
