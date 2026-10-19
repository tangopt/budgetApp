#!/bin/zsh
# Renders every screen, tab and main sheet of Budget to PNGs from the synthetic demo database
# (the UI snapshot harness: App/Snapshots, Sources/BudgetDemo). This is the only way to run the
# app binary from a script: a snapshot build (compiled with SNAPSHOTS, its own bundle id) that
# runs nothing but the harness, always on a freshly built demo database, in an off-screen
# window, with no Dock icon, no focus change and no network. It never opens your real
# database: the app refuses ~/Library/Application Support/Budget and any database without the
# demo's marker, and the build is deleted again at the end.
#
#   scripts/render-snapshots.sh <outDir> [--only property,sheet-tax] [--themes classic,midnight,sunset]
#                               [--appearances light,dark] [--looks light-classic,dark-midnight]
#                               [--scale 1] [--settle 1.6] [--as-of 2026-10-15] [--size 1440x900]
#
# <outDir> (relative to where you run it) must be new, empty, or an earlier output of this
# script (it holds a .budget-snapshots marker). Writes <outDir>/demo.sqlite (+ Evidence/),
# <outDir>/<screen>-<tab>-<appearance>-<theme>.png, <outDir>/index.html and
# <outDir>/wrap-report.txt (the wrap probe: every figure that wraps, truncates or is cut off,
# by route). A full run replaces the folder's PNGs; an --only run adds to them (its report
# covers what it rendered). --looks captures just those appearance-theme pairs instead of
# every appearance in every theme; --as-of is the day the app takes as today (default: the
# demo's 15 Oct 2026); --size the window (default 1440x900).
# Builds into $SNAPSHOT_SCRATCH (default $TMPDIR/budget-snapshots): dd-ui.noindex (the app)
# and spm (the demo-database tool).
set -euo pipefail

if [[ $# -lt 1 || "$1" == -* ]]; then
    echo "usage: $0 <outDir> [--only a,b] [--themes ids] [--appearances light,dark] [--looks light-classic,dark-midnight] [--scale n] [--as-of YYYY-MM-DD] [--size WxH]" >&2
    exit 2
fi

# The output folder, from the caller's working directory, symbolic links resolved (also for
# the parts that don't exist yet), checked before anything is created.
OUT_ARG="$1"
shift
[[ "$OUT_ARG" == /* ]] || OUT_ARG="$PWD/$OUT_ARG"
OUT="${OUT_ARG:A}"
REAL_HOME="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[[ -n "$REAL_HOME" ]] || REAL_HOME="$HOME"
for app_data in "$REAL_HOME/Library/Application Support/Budget" "$HOME/Library/Application Support/Budget" \
                "$REAL_HOME"/Library/Containers/*/Data/Library/Application\ Support/Budget(N); do
    resolved="${app_data:A}"
    if [[ "${OUT:l}" == "${resolved:l}" || "${OUT:l}" == "${resolved:l}/"* ]]; then
        echo "Refusing to write into the app's data folder: $OUT" >&2
        exit 2
    fi
done
MARKER="$OUT/.budget-snapshots"
if [[ -e "$OUT" ]]; then
    [[ -d "$OUT" ]] || { echo "$OUT is a file, not a folder." >&2; exit 2; }
    if [[ -n "$(ls -A "$OUT")" && ( ! -f "$MARKER" || -L "$MARKER" ) ]]; then
        echo "Refusing to write into $OUT: it isn't empty and isn't an earlier snapshot folder." >&2
        exit 2
    fi
fi
mkdir -p "$OUT"
echo "Budget UI snapshots (scripts/render-snapshots.sh)." > "$MARKER"

cd "$(dirname "$0")/.."
SCRATCH="${SNAPSHOT_SCRATCH:-${TMPDIR:-/tmp}/budget-snapshots}"
mkdir -p "$SCRATCH"
DERIVED="$SCRATCH/dd-ui.noindex"
BUNDLE_ID="com.personal.budget.snapshots"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
APP="$DERIVED/Build/Products/Debug/Budget.app"
cleanup() {
    "$LSREGISTER" -u "$APP" 2>/dev/null || true
    defaults delete "$BUNDLE_ID" 2>/dev/null || true
    defaults delete com.personal.budget.snapshot-storage 2>/dev/null || true
    # The snapshot build runs nothing but the harness; it isn't left lying around either.
    if [[ "$APP" == "$DERIVED/Build/Products/Debug/Budget.app" && -d "$APP" ]]; then
        rm -rf "$APP"
    fi
}
trap cleanup EXIT INT TERM

echo "Building the app (Debug, snapshot build)…"
BUILD_LOG="$SCRATCH/render-build.log"
xcodegen generate >/dev/null
if ! xcodebuild -project Budget.xcodeproj -scheme Budget -configuration Debug -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$DERIVED" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
        SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) SNAPSHOTS' build > "$BUILD_LOG" 2>&1 \
   || ! grep -q "\*\* BUILD SUCCEEDED \*\*" "$BUILD_LOG"; then
    grep -E "error:" "$BUILD_LOG" | sort -u | head -20 >&2 || true
    echo "Build failed (log: $BUILD_LOG)." >&2
    exit 1
fi
[[ -x "$APP/Contents/MacOS/Budget" ]] || { echo "Build failed: no app at $APP." >&2; exit 1; }

echo "Building the demo database…"
SPM_LOG="$SCRATCH/render-spm.log"
if ! swift build --scratch-path "$SCRATCH/spm" --product MakeDemoDatabase > "$SPM_LOG" 2>&1; then
    grep -E "error:" "$SPM_LOG" | sort -u | head -20 >&2 || true
    echo "Building MakeDemoDatabase failed (log: $SPM_LOG)." >&2
    exit 1
fi
"$SCRATCH/spm/debug/MakeDemoDatabase" "$OUT/demo.sqlite" --force > "$SCRATCH/render-demo.log"
head -2 "$SCRATCH/render-demo.log"

# A full run starts from an empty set; an --only run adds to (and overwrites in) the folder.
if (( ! ${@[(Ie)--only]} )); then
    rm -f "$OUT"/*.png(N) "$OUT/index.html" "$OUT/wrap-report.txt"
fi
echo "Rendering…"
BUDGET_DB_PATH="$OUT/demo.sqlite" "$APP/Contents/MacOS/Budget" --render-snapshots "$OUT" "$@"
echo "Open $OUT/index.html"
