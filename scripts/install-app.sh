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
[[ -d "$APP" ]] || { echo "Build failed." >&2; exit 1; }

rm -rf /Applications/Budget.app
ditto "$APP" /Applications/Budget.app

# Point macOS at the installed copy (icon, Spotlight, Open With), not a build folder.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$APP" 2>/dev/null || true
"$LSREGISTER" -f /Applications/Budget.app

echo "Installed /Applications/Budget.app"
