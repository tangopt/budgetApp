#!/bin/zsh
# Renders the iPhone app's routes (Sources/MangoUI/Demo/DemoRoutes.swift) to PNGs from the synthetic demo database,
# on the iPhone simulator: a snapshot build of MangoPhone (compiled with SNAPSHOTS, its own bundle id
# ubberninja.mango.ios.snapshots so the simulator's development install is left alone) that runs nothing but
# Phone/Snapshots/PhoneSnapshotRunner.swift. The runner builds the demo database in-process (BudgetDemo) in its own
# temporary folder, renders each route in a 393×852 window, light and dark, at each route's Dynamic Type sizes
# (.large, .xxxLarge, .accessibility3; the gallery also .accessibility5), then again at 393×4000 so everything below
# the fold is measured (<route>-light-<size>-full.png, light only), writes the PNGs and the wrap probe's
# wrap-report.txt to its Documents/snapshots, and exits. A render that measured fewer figures than its route needs
# fails the run.
# This script copies them to <outDir>, prints the report's first two lines and uninstalls the snapshot build.
# Never the phone's real data, the Keychain or iCloud: the snapshot build is unsigned and has no entitlements.
#
#   scripts/render-phone-snapshots.sh <outDir> [--device ipad] [--only gallery,home] [--theme <id>|all]
#
# --theme <id> (step 8): renders in that theme set, palette and fonts (mango by default; classic, editorial, clear,
# studio, calm, library, flat), several as a,b, or all eight with all; with more than one, each PNG's name starts
# with the set's id (flat-home-light-large.png). --font <id> (step 16) is kept as an alias: the set the one-time
# migration picks for that font on the Classic colour theme (new-york -> editorial, inter -> flat, ...).
#
# --device ipad (step 8): boots IOS_SIM_DEVICE (default "iPad Pro 13-inch (M5)") and renders the iPad routes
# (DemoRoute.pad) at 834×1194, 1194×834, 1032×1376 and 1376×1032, light and dark, at .large and .xxxLarge, as
# <route>-<w>x<h>-<appearance>-<size>.png; the iPhone run skips them. The four sizes are the 11" iPad portrait
# (834×1194) and landscape (1194×834) and the 13" portrait (1032×1376) and landscape (1376×1032): every iPad run renders
# all four (step 10), so no size flag is needed.
#
# <outDir> (relative to where you run it) must be new, empty, or an earlier output of this script (it holds a
# .mango-phone-snapshots marker); its PNGs are replaced. IOS_SIM_DEVICE picks the simulator (default "iPhone 17"; a
# booted one of that name first). Builds into $SNAPSHOT_SCRATCH (default $TMPDIR/mango-phone-snapshots).
# Exits non-zero if the build, the run or the copy fails; the wrap report's violations are for the caller to read.
set -euo pipefail

if [[ $# -lt 1 || "$1" == -* ]]; then
    echo "usage: $0 <outDir> [--device ipad] [--only a,b] [--theme id|a,b|all]" >&2
    exit 2
fi
OUT_ARG="$1"
shift
# --theme <id> goes to the runner through an environment variable (SIMCTL_CHILD_ passes it into the app).
THEME_ID="mango"
ARGS=()
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--theme" && $# -ge 2 ]]; then THEME_ID="$2"; shift 2
    elif [[ "$1" == "--font" && $# -ge 2 ]]; then
        case "$2" in
            new-york) THEME_ID="editorial" ;; source-serif-4) THEME_ID="library" ;;
            ibm-plex-sans|ibm-plex-mono) THEME_ID="studio" ;; atkinson-hyperlegible|lexend) THEME_ID="clear" ;;
            manrope|source-sans-3|public-sans) THEME_ID="calm" ;; sf-rounded) THEME_ID="mango" ;; inter) THEME_ID="flat" ;;
            *) THEME_ID="classic" ;;
        esac
        shift 2
    else ARGS+=("$1"); shift; fi
done
set -- "${ARGS[@]}"
[[ "$OUT_ARG" == /* ]] || OUT_ARG="$PWD/$OUT_ARG"
OUT="${OUT_ARG:A}"
MARKER="$OUT/.mango-phone-snapshots"
if [[ -e "$OUT" ]]; then
    [[ -d "$OUT" ]] || { echo "$OUT is a file, not a folder." >&2; exit 2; }
    if [[ -n "$(ls -A "$OUT")" && ( ! -f "$MARKER" || -L "$MARKER" ) ]]; then
        echo "Refusing to write into $OUT: it isn't empty and isn't an earlier phone snapshot folder." >&2
        exit 2
    fi
fi
mkdir -p "$OUT"
echo "Mango iPhone snapshots (scripts/render-phone-snapshots.sh)." > "$MARKER"

cd "$(dirname "$0")/.."
SCRATCH="${SNAPSHOT_SCRATCH:-${TMPDIR:-/tmp}/mango-phone-snapshots}"
mkdir -p "$SCRATCH"
DERIVED="$SCRATCH/dd-phone.noindex"
BUNDLE_ID="ubberninja.mango.ios.snapshots"
APP="$DERIVED/Build/Products/Debug-iphonesimulator/Mango.app"
DEVICE_NAME="${IOS_SIM_DEVICE:-iPhone 17}"
if [[ " $* " == *" --device ipad "* ]]; then
    DEVICE_NAME="${IOS_SIM_DEVICE:-iPad Pro 13-inch (M5)}"
fi

# The simulator: a booted one with that name, else the first available one, booted now.
UDID="$(xcrun simctl list devices available | grep -F "    $DEVICE_NAME (" | grep "(Booted)" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/' || true)"
if [[ -z "$UDID" ]]; then
    UDID="$(xcrun simctl list devices available | grep -F "    $DEVICE_NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/' || true)"
    [[ -n "$UDID" ]] || { echo "No simulator named $DEVICE_NAME." >&2; exit 1; }
    echo "Booting $DEVICE_NAME ($UDID)…"
    xcrun simctl boot "$UDID" 2>/dev/null || true
fi
xcrun simctl bootstatus "$UDID" -b >/dev/null

cleanup() {
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "Building MangoPhone (Debug, snapshot build)…"
BUILD_LOG="$SCRATCH/render-build.log"
xcodegen generate >/dev/null
if ! xcodebuild -project Mango.xcodeproj -scheme MangoPhone -configuration Debug -destination "id=$UDID" \
        -derivedDataPath "$DERIVED" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" CODE_SIGNING_ALLOWED=NO \
        SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) SNAPSHOTS' build > "$BUILD_LOG" 2>&1 \
   || ! grep -q "\*\* BUILD SUCCEEDED \*\*" "$BUILD_LOG"; then
    grep -E "error:" "$BUILD_LOG" | sort -u | head -20 >&2 || true
    echo "Build failed (log: $BUILD_LOG)." >&2
    exit 1
fi
[[ -d "$APP" ]] || { echo "Build failed: no app at $APP." >&2; exit 1; }
# The override above renames the embedded widget extension too, so it no longer sits under the app's id; the harness
# doesn't need it.
rm -rf "$APP/PlugIns"

echo "Rendering on $DEVICE_NAME ($UDID)…"
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"
# --console-pty waits for the app to exit.
RUN_LOG="$SCRATCH/render-run.log"
SIMCTL_CHILD_MANGO_SNAPSHOT_THEME="$THEME_ID" xcrun simctl launch --console-pty --terminate-running-process "$UDID" "$BUNDLE_ID" --render-snapshots "$@" > "$RUN_LOG" 2>&1 || true

CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
SNAPS="$CONTAINER/Documents/snapshots"
[[ -f "$SNAPS/wrap-report.txt" || -f "$SNAPS/error.txt" ]] || { echo "The run wrote no wrap report (log: $RUN_LOG)." >&2; tail -20 "$RUN_LOG" >&2; exit 1; }

rm -f "$OUT"/*.png(N) "$OUT/wrap-report.txt"
cp "$SNAPS"/*.png(N) "$OUT/" 2>/dev/null || true
[[ -f "$SNAPS/wrap-report.txt" ]] && cp "$SNAPS/wrap-report.txt" "$OUT/"
echo "$(ls "$OUT"/*.png(N) | wc -l | tr -d ' ') PNGs in $OUT"
[[ -f "$OUT/wrap-report.txt" ]] && head -2 "$OUT/wrap-report.txt"
# Routes' assertions about their figures (Home's net worth equals the Accounts screen's).
[[ -f "$OUT/wrap-report.txt" ]] && sed -n '/^Route checks:/,/^Figures checked by render:/p' "$OUT/wrap-report.txt" | sed '$d'
# A render that measured too little (or any other runner failure) fails the run.
if [[ -f "$SNAPS/error.txt" ]]; then
    cat "$SNAPS/error.txt" >&2
    exit 1
fi
