#!/bin/zsh
# Builds Budget in Release and installs it to /Applications, so it runs like any other app.
# Re-run after pulling new changes to update the installed copy. Your data stays where it is
# (~/Library/Application Support/Budget), shared by every copy of the app.
set -euo pipefail

cd "$(dirname "$0")/.."
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

if pgrep -x Budget >/dev/null; then
    echo "Quit Budget first, then run this again." >&2
    exit 1
fi

xcodegen generate
xcodebuild -project Budget.xcodeproj -scheme Budget -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$BUILD_DIR" build \
    | grep -E "error:|warning:|BUILD" | grep -v appintents || true

APP="$BUILD_DIR/Build/Products/Release/Budget.app"
[[ -x "$APP/Contents/MacOS/Budget" ]] || { echo "Build failed." >&2; exit 1; }

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

echo "Installed /Applications/Budget.app"
