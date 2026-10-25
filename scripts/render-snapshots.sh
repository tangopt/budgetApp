#!/bin/zsh
# Renders every screen, tab and main sheet of Mango to PNGs from the synthetic demo database
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
#   scripts/render-snapshots.sh <outDir> --perf tenancies [--size 1100x700]
#
# <outDir> (relative to where you run it) must be new, empty, or an earlier output of this
# script (it holds a .budget-snapshots marker). Writes <outDir>/demo.sqlite (+ Evidence/),
# <outDir>/<screen>-<tab>-<appearance>-<theme>.png, <outDir>/index.html and
# <outDir>/wrap-report.txt (the wrap probe: every figure that wraps, truncates or is cut off,
# by route). A full run replaces the folder's PNGs; an --only run adds to them (its report
# covers what it rendered). --looks captures just those appearance-theme pairs instead of
# every appearance in every theme; --as-of is the day the app takes as today (default: the
# demo's 15 Oct 2026); --size the window (default 1440x900).
# --perf tenancies times the Tenancies tab's receipt panel instead (`PanelTiming`), on a demo
# with "Tenancy L" (62 receipts, each with its PDF and credit): <outDir>/perf-report.txt.
#
# Fix rounds (the full run takes ~20 minutes):
#   --quick              one look only (light-classic) instead of 2 appearances x 3 themes. Same wrap
#                        probe, ~1/6 of the captures. (An explicit --looks wins.)
#   --routes a,b,c       only the routes whose name contains one of these (same matching as --only).
#   --changed [base-ref] only the routes the files changed since base-ref (default: the merge-base with
#                        main; committed, staged, unstaged and untracked files count) can affect. A change in
#                        App/DesignSystem, App/Shared, Sources/ (BudgetCore, BudgetDemo, ...), the app shell,
#                        the snapshot harness or the project files, or in a file this script can't place,
#                        renders ALL routes. The chosen routes and why are printed first.
# An --only / --routes / --changed run adds to the folder's PNGs; run without them for the full set.
# Builds into $SNAPSHOT_SCRATCH (default $TMPDIR/budget-snapshots): dd-ui.noindex (the app)
# and spm (the demo-database tool).
set -euo pipefail

if [[ $# -lt 1 || "$1" == -* ]]; then
    echo "usage: $0 <outDir> [--quick] [--routes a,b] [--changed [base-ref]] [--only a,b] [--themes ids] [--appearances light,dark] [--looks light-classic,dark-midnight] [--scale n] [--as-of YYYY-MM-DD] [--size WxH]" >&2
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
echo "Mango UI snapshots (scripts/render-snapshots.sh)." > "$MARKER"

cd "$(dirname "$0")/.."

# Script-level options (the rest goes to the app as it is): --quick, --routes, --changed [base-ref].
SELECT_ONLY=0; QUICK=0; ROUTES=""; CHANGED=0; CHANGED_BASE=""
ARGS=()
while (( $# )); do
    case "$1" in
        --quick) QUICK=1; shift ;;
        --routes)
            [[ $# -ge 2 ]] || { echo "--routes needs a comma-separated list" >&2; exit 2; }
            ROUTES="$2"; shift 2 ;;
        --changed)
            CHANGED=1; shift
            if (( $# )) && [[ "$1" != --* ]]; then CHANGED_BASE="$1"; shift; fi ;;
        --select-only) SELECT_ONLY=1; shift ;;   # print which routes would be rendered, build nothing
        *) ARGS+=("$1"); shift ;;
    esac
done
if [[ -n "$ROUTES" ]] && (( CHANGED )); then echo "--routes and --changed can't be combined" >&2; exit 2; fi
if [[ -n "$ROUTES" || $CHANGED -eq 1 ]] && (( ${ARGS[(Ie)--only]} )); then echo "--only can't be combined with --routes or --changed" >&2; exit 2; fi

# The route-name fragments a changed file can affect: ALL, NONE, or a comma list (--only matching).
routes_for_file() {
    case "$1" in
        App/DesignSystem/*|App/Shared/*|App/Snapshots/*|App/Assets.xcassets/*|Sources/*|Config/*) echo ALL ;;
        App/ContentView.swift|App/BudgetApp.swift|App/AppEnvironment.swift|App/LaunchView.swift|App/Info.plist|App/Mango.entitlements) echo ALL ;;
        project.yml|Package.swift|Package.resolved|scripts/render-snapshots.sh) echo ALL ;;
        App/Dashboard/*) echo "dashboard" ;;
        App/Search/*) echo "search" ;;
        App/Budget/*) echo "budget,sheet-,search" ;;
        App/Forecast/*) echo "forecast,auth-locked_over_scenario_lab" ;;
        App/Accounts/*) echo "accounts,sheet-,imports-review_remap" ;;
        App/Categories/*) echo "categories,sheet-" ;;
        App/Uncategorized/*) echo "uncategorized,sheet-" ;;
        App/Documents/*) echo "documents,missing_evidence,sheet-,imports-" ;;
        App/DocumentImport/*) echo "imports-,sheet-" ;;
        App/Import/*) echo "imports-,sheet-" ;;
        App/Rules/*) echo "rules,auth-locked_over_rules_search,sheet-" ;;
        App/Property/*) echo "property,tax_years,sheet-,imports-" ;;
        App/Tax/*) echo "tax_years,property,sheet-,imports-" ;;
        App/Settings/*|App/Sync/*) echo "settings,sheet-,imports-" ;;
        App/Auth/*) echo "auth-,settings,rules,forecast" ;;
        Tests/*|docs/*|Phone/*|.superpowers/*|*.md) echo NONE ;;
        scripts/*) echo NONE ;;
        *) echo ALL ;;
    esac
}

ONLY_FROM_SELECTION=""
if [[ -n "$ROUTES" ]]; then
    ONLY_FROM_SELECTION="$ROUTES"
    echo "Routes: $ROUTES (--routes: names containing any of these)"
elif (( CHANGED )); then
    if [[ -z "$CHANGED_BASE" ]]; then
        CHANGED_BASE="$(git merge-base HEAD main 2>/dev/null || true)"
    fi
    changed_files=()
    if [[ -n "$CHANGED_BASE" ]] && git rev-parse --verify -q "$CHANGED_BASE^{commit}" >/dev/null; then
        changed_files=("${(@f)$( { git diff --name-only "$CHANGED_BASE"; git ls-files -o --exclude-standard; } | sort -u)}")
        changed_files=("${(@)changed_files:#}")
        echo "Routes: --changed since ${CHANGED_BASE[1,10]} (${#changed_files} changed files)"
        want=()
        all_reason=""
        for f in "${changed_files[@]}"; do
            r="$(routes_for_file "$f")"
            if [[ "$r" == ALL ]]; then all_reason="$f"; break; fi
            [[ "$r" == NONE ]] && continue
            want+=("${(@s:,:)r}")
            echo "  $f -> $r"
        done
        if [[ -n "$all_reason" ]]; then
            echo "  $all_reason affects every screen (or can't be placed): rendering ALL routes"
        elif (( ${#want} == 0 )); then
            echo "  No changed file can affect a route: nothing to render."
            exit 0
        else
            ONLY_FROM_SELECTION="${(j:,:)${(@u)want}}"
            echo "  Rendering routes containing: $ONLY_FROM_SELECTION"
        fi
    else
        echo "Routes: --changed couldn't find the base (${CHANGED_BASE:-merge-base with main}): rendering ALL routes"
    fi
fi
if (( SELECT_ONLY )); then exit 0; fi
set -- "${ARGS[@]}"
[[ -n "$ONLY_FROM_SELECTION" ]] && set -- "$@" --only "$ONLY_FROM_SELECTION"
if (( QUICK )) && (( ! ${@[(Ie)--looks]} )); then
    set -- "$@" --looks light-classic
    echo "Quick: one look (light-classic)."
fi

SCRATCH="${SNAPSHOT_SCRATCH:-${TMPDIR:-/tmp}/budget-snapshots}"
mkdir -p "$SCRATCH"
DERIVED="$SCRATCH/dd-ui.noindex"
BUNDLE_ID="com.personal.budget.snapshots"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
APP="$DERIVED/Build/Products/Debug/Mango.app"
cleanup() {
    "$LSREGISTER" -u "$APP" 2>/dev/null || true
    defaults delete "$BUNDLE_ID" 2>/dev/null || true
    defaults delete com.personal.budget.snapshot-storage 2>/dev/null || true
    # The snapshot build runs nothing but the harness; it isn't left lying around either.
    if [[ "$APP" == "$DERIVED/Build/Products/Debug/Mango.app" && -d "$APP" ]]; then
        rm -rf "$APP"
    fi
}
trap cleanup EXIT INT TERM

echo "Building the app (Debug, snapshot build)…"
BUILD_LOG="$SCRATCH/render-build.log"
xcodegen generate >/dev/null
# Always signed to run locally, never with the team (its own bundle id has no registered profile).
if ! xcodebuild -project Mango.xcodeproj -scheme Mango -configuration Debug -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$DERIVED" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
        DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGN_ENTITLEMENTS= ENABLE_HARDENED_RUNTIME=NO \
        SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) SNAPSHOTS' build > "$BUILD_LOG" 2>&1 \
   || ! grep -q "\*\* BUILD SUCCEEDED \*\*" "$BUILD_LOG"; then
    grep -E "error:" "$BUILD_LOG" | sort -u | head -20 >&2 || true
    echo "Build failed (log: $BUILD_LOG)." >&2
    exit 1
fi
[[ -x "$APP/Contents/MacOS/Mango" ]] || { echo "Build failed: no app at $APP." >&2; exit 1; }

echo "Building the demo database…"
SPM_LOG="$SCRATCH/render-spm.log"
if ! swift build --scratch-path "$SCRATCH/spm" --product MakeDemoDatabase > "$SPM_LOG" 2>&1; then
    grep -E "error:" "$SPM_LOG" | sort -u | head -20 >&2 || true
    echo "Building MakeDemoDatabase failed (log: $SPM_LOG)." >&2
    exit 1
fi
DEMO_OPTIONS=()
(( ${@[(Ie)--perf]} )) && DEMO_OPTIONS=(--long-tenancy 62)
"$SCRATCH/spm/debug/MakeDemoDatabase" "$OUT/demo.sqlite" --force "${DEMO_OPTIONS[@]}" > "$SCRATCH/render-demo.log"
head -2 "$SCRATCH/render-demo.log"

# A full run starts from an empty set; an --only run adds to (and overwrites in) the folder.
if (( ! ${@[(Ie)--only]} )); then
    rm -f "$OUT"/*.png(N) "$OUT/index.html" "$OUT/wrap-report.txt"
fi
echo "Rendering…"
BUDGET_DB_PATH="$OUT/demo.sqlite" "$APP/Contents/MacOS/Mango" --render-snapshots "$OUT" "$@"
echo "Open $OUT/index.html"
