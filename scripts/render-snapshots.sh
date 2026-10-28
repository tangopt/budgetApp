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
#                        main; committed, staged, unstaged, untracked and deleted files count, a rename as
#                        both paths) can affect. A file under App/<Folder>/ selects its folder's routes and
#                        those of every folder whose code uses a name it declares (followed through
#                        DesignSystem, Shared and its own folder; the gallery and harness routes that use
#                        them too). A change in App/DesignSystem, App/Shared, Sources/ (BudgetCore,
#                        BudgetDemo, ...), the app shell, the snapshot harness or the project files, a name
#                        the shell uses, or a file this script can't read or place renders ALL routes; one
#                        under Tools/, Tests/, docs/ or another script renders none. The chain (file ->
#                        names -> users -> folders -> routes) is printed first.
#   scripts/render-snapshots.sh --self-test   checks the --changed selection on known files (builds nothing).
# An --only / --routes / --changed run adds to the folder's PNGs; run without them for the full set.
# Builds into $SNAPSHOT_SCRATCH (default $TMPDIR/budget-snapshots): dd-ui.noindex (the app)
# and spm (the demo-database tool).
set -euo pipefail

# ---- --changed: which routes a changed file can affect ------------------------------------------
# A file under App/<Folder>/ selects its folder's routes, then those of every App folder whose code
# uses a name the file declares (top-level types, functions, constants; for an extension of a system
# or BudgetCore type, its members, matched after a dot). A user in DesignSystem or Shared (no screen
# of their own) or in the file's own folder is followed in turn, so a Budget helper used by a Budget
# view that Forecast embeds still selects Forecast. A user in another folder selects that folder and
# is not followed further: the scan is one folder deep, which catches the cross-folder uses the
# review listed (DashboardFormat, TwoUpRow, NonGBPImportCaption, AccountsFormat, ...).
# Users in the app shell (ContentView, AppEnvironment, ...) mean ALL, unless the name is a screen's
# entry point the shell only shows on that screen. In the snapshot harness, a use inside a route
# selects that route (the gallery's included); a use in a harness helper is followed to the routes
# that call it; a use in the harness's machinery (runner, capture, wrap probe) means ALL. A file
# that can't be read or declares nothing this can read, a user in a folder with no route mapping,
# or a harness helper no route reaches renders ALL. Tools/ (the app doesn't link it), Tests/, docs
# and the other scripts render nothing. Words in comments and string text don't count as uses.

# The route-name fragments (--only matching) that show each App folder's screens and sheets.
typeset -gA FOLDER_ROUTES=(
    Dashboard      "dashboard"
    Search         "search"
    Budget         "budget,sheet-,search"
    Forecast       "forecast,auth-locked_over_scenario_lab"
    Salary         "salary"
    Accounts       "accounts,sheet-,imports-review_remap"
    Categories     "categories,sheet-"
    Uncategorized  "uncategorized,sheet-"
    Documents      "documents,missing_evidence,sheet-,imports-"
    DocumentImport "imports-,sheet-"
    Import         "imports-,sheet-"
    Rules          "rules,auth-locked_over_rules_search,sheet-"
    Property       "property,tax_years,sheet-,imports-"
    Tax            "tax_years,property,sheet-,imports-"
    Settings       "settings,sheet-,imports-"
    Sync           "settings,sheet-,imports-"
    Auth           "auth-,settings,rules,forecast"
)
# The snapshot harness's machinery (any use there of a changed name renders ALL) and its --perf mode
# (no route); the other files of App/Snapshots hold the routes and their helpers.
HARNESS_MACHINERY=(SnapshotRunner.swift SnapshotCapture.swift SnapshotMode.swift WrapProbe.swift)
HARNESS_PERF=(PanelTiming.swift)
# Folders with no screen of their own: a file there that uses a changed name is followed to its users.
LIBRARY_FOLDERS=(DesignSystem Shared)
# The screens' entry points: the shell names them only to show that screen (whose routes the
# declaring folder already selects), so the shell using them doesn't make every route depend on them.
SHELL_ENTRY_POINTS=(
    DashboardView DashboardViewModel SearchView SearchViewModel BudgetGridView BudgetGridViewModel
    ScenarioLabView ScenarioLabViewModel AccountsView AccountsViewModel CategoriesView CategoriesViewModel
    UncategorizedView UncategorizedViewModel DocumentsView DocumentsViewModel MissingEvidenceView
    MissingEvidenceViewModel ImportsScreen RulesView RulesViewModel PropertyView PropertyViewModel
    TaxYearsView TaxYearsViewModel SettingsView
)

# The names a Swift file declares for other files, one "kind name" per line: top-level (column 0),
# not private: struct/class/enum/protocol/actor/func/typealias/let/var ("decl"), the type an
# extension extends ("extension"), and the non-private members of a top-level extension ("member",
# with the extended type).
DECL_AWK='
function attrs(s) { while (match(s, /^@[A-Za-z_][A-Za-z0-9_.]*(\([^)]*\))?[ \t]+/)) s = substr(s, RLENGTH + 1); return s }
function mods(s) { while (match(s, /^(public|internal|open|final|nonisolated|indirect|static|package|override|mutating|private\(set\)|fileprivate\(set\))[ \t]+/)) s = substr(s, RLENGTH + 1); return s }
FNR == 1 { inext = 0 }
{
    line = $0
    if (inext && line ~ /^}/) { inext = 0; next }
    if (inext) {
        if (line !~ /^    [^ \t}\/]/) next
        m = attrs(substr(line, 5))
        if (m ~ /^(private|fileprivate)[ \t]/ || m ~ /[ \t](private|fileprivate)[ \t]/) next
        m = mods(m)
        if (match(m, /^(func|var|let|typealias|struct|class|enum|case)[ \t]+`?[A-Za-z_][A-Za-z0-9_]*/)) {
            d = substr(m, RSTART, RLENGTH); sub(/^[a-z]+[ \t]+`?/, "", d); print FILENAME "\tmember\t" d "\t" extbase
        }
        next
    }
    if (line !~ /^[@A-Za-z]/) next
    l = attrs(line)
    if (l ~ /^(private|fileprivate)[ \t]/) next
    l = mods(l)
    if (match(l, /^(struct|class|enum|protocol|actor|func|typealias|let|var|extension)[ \t]+`?[A-Za-z_][A-Za-z0-9_.]*/)) {
        kw = l; sub(/[ \t].*/, "", kw)
        d = substr(l, RSTART, RLENGTH); sub(/^[a-z]+[ \t]+`?/, "", d)
        if (kw == "extension") { sub(/\..*/, "", d); extbase = d; print FILENAME "\textension\t" d; if (l ~ /\{[^}]*$/) inext = 1 }
        else print FILENAME "\tdecl\t" d
    }
}'

# Shared by the two scans below: -v names="a b" (any use), -v members="c d" (only after a dot) and
# -v calls="e f" (after a dot or before "(").
COMMON_AWK='
# The line without string text, interpolations kept: "a \(b) c" -> " b ". A multi-line string
# (""") carries over to the next lines.
function code(s,   out, i, c, n, instr, d) {
    if (index(s, "\"") == 0 && !inml) return s
    out = ""; n = length(s); instr = inml; d = 0
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (d > 0) { if (c == "(") d++; else if (c == ")") d--; if (d > 0) out = out c; else out = out " "; continue }
        if (instr) {
            if (c == "\\") { if (substr(s, i + 1, 1) == "(") { d = 1; out = out " " } i++; continue }
            if (inml && substr(s, i, 3) == "\"\"\"") { inml = 0; instr = 0; i += 2; out = out " "; continue }
            if (!inml && c == "\"") { instr = 0; out = out " " }
            continue
        }
        if (substr(s, i, 3) == "\"\"\"") { inml = 1; instr = 1; i += 2; continue }
        if (c == "\"") { instr = 1; continue }
        out = out c
    }
    return out
}
FNR == 1 { inml = 0 }
BEGIN {
    n = split(names, list, " "); for (i = 1; i <= n; i++) want[list[i]] = 1
    n = split(members, list, " "); for (i = 1; i <= n; i++) wantm[list[i]] = 1
    n = split(calls, list, " "); for (i = 1; i <= n; i++) wantc[list[i]] = 1
}
# The names a code line uses, into hits[1..count]: a name as any word, a member only after a dot
# (x.member, .member, \.member), a call (-v calls) after a dot or before "(".
function uses(cl,   rest, t, prev, after, k) {
    delete seenhere; k = 0; rest = cl
    while (match(rest, /[A-Za-z_][A-Za-z0-9_]*/)) {
        t = substr(rest, RSTART, RLENGTH)
        prev = (RSTART > 1) ? substr(rest, RSTART - 1, 1) : ""
        after = substr(rest, RSTART + RLENGTH, 1)
        if ((t in want || (t in wantm && prev == ".") || (t in wantc && (prev == "." || after == "("))) && !(t in seenhere)) {
            seenhere[t] = 1; hits[++k] = t
        }
        rest = substr(rest, RSTART + RLENGTH)
    }
    return k
}
'

# Where names are used: "file<TAB>line<TAB>name" for every use on a non-comment line. String text
# doesn't count; interpolations do.
REFS_AWK="$COMMON_AWK"'
/^[ \t]*\/\// { next }
{
    k = uses(code($0))
    for (i = 1; i <= k; i++) print FILENAME "\t" FNR "\t" hits[i]
}'

# Uses of names in the snapshot harness, placed by route: for each use, "file:line<TAB>ROUTE<TAB>fragment"
# (the innermost SnapshotRoute(name:) / screen("a", "b") / sheet("x") / samplesReview("x") around it),
# "ROUTES<TAB>a,b" (a helper function or route list holding those routes), "HELPER<TAB>kind:name" (a
# helper with no route of its own, whose callers are looked up next: func:f is called as f( or .f,
# var:v used as .v, type:T, for a view's body, used as T) or "ALL<TAB>why".
SNAP_AWK="$COMMON_AWK"'
function opens(s,   t) { t = s; return gsub(/\{/, "", t) }
function closes(s,  t) { t = s; return gsub(/\}/, "", t) }
function parens(s,  a, b) { a = s; b = s; return gsub(/\(/, "", a) - gsub(/\)/, "", b) }
function push(kind, name) { sp++; skind[sp] = kind; sname[sp] = name; sdepth[sp] = depth; sopen[sp] = 0; sparen[sp] = 0; sid[sp] = ++ids }
FNR == 1 { sp = 0; depth = 0 }
/^[ \t]*\/\// { next }
{
    line = $0
    cl = code(line)
    base = sp
    declared = ""
    frag = ""; isroute = 0
    if (match(line, /SnapshotRoute\(name: "[^"]*/)) { frag = substr(line, RSTART + 21, RLENGTH - 21); isroute = 1 }
    else if (match(line, /(^|[^A-Za-z0-9_.])screen\("[A-Za-z0-9_]+"(, "[^"]*")?/)) {
        s = substr(line, RSTART, RLENGTH); sub(/^[^"]*"/, "", s); a = s; sub(/".*/, "", a); b = ""
        if (s ~ /, "/) { b = s; sub(/^[^,]*, "/, "", b); sub(/"$/, "", b) }
        frag = a "-" b; isroute = 1
    }
    else if (match(line, /(^|[^A-Za-z0-9_.])sheet\("[^"]*/)) { s = substr(line, RSTART, RLENGTH); sub(/^[^"]*"/, "", s); frag = "sheet-" s; isroute = 1 }
    else if (match(line, /(^|[^A-Za-z0-9_.])samplesReview\("[^"]*/)) { s = substr(line, RSTART, RLENGTH); sub(/^[^"]*"/, "", s); frag = "imports-" s; isroute = 1 }
    else if (match(cl, /(^|[ \t])(struct|class|enum|actor|extension)[ \t]+[A-Za-z_][A-Za-z0-9_.]*/)) {
        d = substr(cl, RSTART, RLENGTH); kw = d; sub(/^[ \t]*/, "", kw); sub(/[ \t].*/, "", kw); sub(/^[ \t]*[a-z]+[ \t]+/, "", d)
        push(kw, d); declared = d
    }
    else if (match(cl, /(^|[ \t])(func|var)[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
        d = substr(cl, RSTART, RLENGTH); kw = d; sub(/^[ \t]*/, "", kw); sub(/[ \t].*/, "", kw); sub(/^[ \t]*(func|var)[ \t]+/, "", d)
        push(kw, d); declared = d
    }
    if (isroute) {
        sub(/\\\(.*/, "", frag)
        push("route", frag)
        for (j = 1; j < sp; j++) if (skind[j] == "func" || skind[j] == "var") {
            if (frag == "") funcall[sid[j]] = 1; else funcroutes[sid[j]] = funcroutes[sid[j]] (funcroutes[sid[j]] == "" ? "" : ",") frag
        }
    }
    k = uses(cl)
    for (i = 1; i <= k; i++) if (hits[i] != declared) {
        words[i] = hits[i]
        where = FILENAME ":" FNR
        hit = 0
        for (j = sp; j >= 1; j--) if (skind[j] == "route") {
            if (sname[j] == "") print where "\tALL\ta route whose name is built at run time\t" words[i]
            else print where "\tROUTE\t" sname[j] "\t" words[i]
            hit = 1; break
        }
        # Outside a route: the helper whose callers lead to routes. Inside a struct or class (a view the
        # harness defines), that type; inside a namespace (an enum or an extension), the function or
        # property directly in it; at the top level, the outermost function.
        if (!hit) {
            tj = 0
            for (j = sp; j >= 1; j--) if (skind[j] ~ /^(struct|class|actor|enum|extension)$/) { tj = j; break }
            hj = 0
            if (tj > 0 && skind[tj] ~ /^(struct|class|actor)$/) helper = "type:" sname[tj]
            else {
                hj = tj + 1
                helper = (hj <= sp && (skind[hj] == "func" || skind[hj] == "var")) ? skind[hj] ":" sname[hj] : ""
            }
            if (helper != "") { pend[++np] = where "\t" (hj > 0 ? sid[hj] : "-") "\t" helper "\t" words[i]; hit = 1 }
        }
        if (!hit) print where "\tALL\toutside any route or helper\t" words[i]
    }
    depth += opens(cl) - closes(cl)
    for (j = base + 1; j <= sp; j++) sparen[j] += parens(cl)
    while (sp > 0) {
        if (depth > sdepth[sp]) { sopen[sp] = 1; break }
        if (sopen[sp] || sparen[sp] <= 0 || depth < sdepth[sp]) { sp--; continue }
        break
    }
    for (j = 1; j <= sp; j++) if (depth > sdepth[j]) sopen[j] = 1
}
END {
    for (p = 1; p <= np; p++) {
        split(pend[p], f, "\t")
        if (f[2] in funcall) print f[1] "\tALL\thelper " f[3] " holds a route whose name is built at run time\t" f[4]
        else if (f[2] in funcroutes) print f[1] "\tROUTES\t" funcroutes[f[2]] "\t" f[4]
        else print f[1] "\tHELPER\t" f[3] "\t" f[4]
    }
}'

# The names other files can use from these Swift files, "decl<TAB>name" or "member<TAB>name": an
# extension of an App type counts as that type; of a system or BudgetCore type, as its members (a
# protocol's requirement, like id or body, as the extended type: `.id` is everywhere).
typeset -gA APP_TYPES
REQUIREMENT_MEMBERS=(id body description debugDescription hash hashValue rawValue allCases init)
names_declared_in() {
    local file kind name ext
    awk "$DECL_AWK" "$@" > "$SELECT_TMP/decls"
    while IFS=$'\t' read -r file kind name ext; do
        case "$kind" in
            decl) print -r -- "decl"$'\t'"$name" ;;
            extension) [[ -z "${APP_TYPES[$name]-}" ]] || print -r -- "decl"$'\t'"$name" ;;
            member)
                if [[ -n "${APP_TYPES[$ext]-}" ]]; then continue    # an App type's own name finds its users
                elif (( ${REQUIREMENT_MEMBERS[(Ie)$name]} )); then print -r -- "decl"$'\t'"$ext"
                else print -r -- "member"$'\t'"$name"; fi ;;
        esac
    done < "$SELECT_TMP/decls" | sort -u
}
# Splits names_declared_in's lines into the caller's `names` and `members`.
split_declared() {
    local line
    names=() members=()
    for line in "$@"; do
        case "$line" in
            decl$'\t'*) names+=("${line#*$'\t'}") ;;
            member$'\t'*) members+=("${line#*$'\t'}") ;;
        esac
    done
}

# Selects the routes for one changed file under App/<Folder>/. Prints the chain; adds to the caller's
# `want` and sets `all_reason` when every route must render. $1 path, $2 base ref.
select_for_app_file() {
    local cfile="$1" base="$2"
    local folder="${${cfile#App/}%%/*}" rf line tok rel f k n
    if [[ -z "${FOLDER_ROUTES[$folder]-}" ]]; then all_reason="$cfile (App/$folder has no route mapping)"; return; fi
    if [[ "$cfile" != *.swift ]]; then all_reason="$cfile (not a Swift file: can't follow its uses)"; return; fi
    if (( ${#APP_TYPES} == 0 )); then
        awk "$DECL_AWK" App/**/*.swift(N) > "$SELECT_TMP/all-decls"
        while IFS=$'\t' read -r f k n; do [[ "$k" != decl ]] || APP_TYPES[$n]=1; done < "$SELECT_TMP/all-decls"
        APP_TYPES[__indexed__]=1
    fi
    # The file as it is now and as it was at the base (a deleted or renamed file only has the latter).
    local -a sources=()
    [[ -f "$cfile" ]] && sources+=("$cfile")
    local old="$SELECT_TMP/base-${cfile//\//_}"
    git show "$base:$cfile" > "$old" 2>/dev/null && sources+=("$old")
    if (( ${#sources} == 0 )); then all_reason="$cfile (can't read it now or at the base)"; return; fi
    local -a names=() members=() declared=("${(@f)$(names_declared_in "${sources[@]}")}")
    split_declared "${declared[@]}"
    if (( ${#names} + ${#members} == 0 )); then all_reason="$cfile (no declaration this script can read)"; return; fi

    local -A folders=([$folder]=1) visited=([$cfile]=1) snapnames=() snapmembers=()
    local -a wave=("$cfile") next=()
    local -a swift_files=(App/**/*.swift(N))
    print -r -- "  $cfile declares: ${(j: :)names}${members:+ (members: ${(j: :)members})}"
    while (( ${#wave} )); do
        next=()
        awk -v names="${(j: :)names}" -v members="${(j: :)members}" "$REFS_AWK" "${swift_files[@]}" > "$SELECT_TMP/refs"
        while IFS=$'\t' read -r rf line tok; do
            (( ${+visited[$rf]} )) && continue
            rel="${rf#App/}"
            if [[ "$rel" != */* ]]; then
                (( ${SHELL_ENTRY_POINTS[(Ie)$tok]} )) && continue
                all_reason="$cfile (the app shell's $rf uses $tok)"; return
            fi
            f="${rel%%/*}"
            if [[ "$f" == Snapshots ]]; then
                if (( ${HARNESS_PERF[(Ie)${rf:t}]} )); then continue
                elif (( ${HARNESS_MACHINERY[(Ie)${rf:t}]} )); then
                    # It holds each screen's model (SnapshotScreenModels) for that screen's routes to set up.
                    (( ${SHELL_ENTRY_POINTS[(Ie)$tok]} )) && continue
                    all_reason="$cfile (the snapshot harness's machinery, $rf, uses $tok)"; return
                fi
                if (( ${names[(Ie)$tok]} )); then snapnames[$tok]=1; else snapmembers[$tok]=1; fi
                continue
            fi
            if [[ -z "${FOLDER_ROUTES[$f]-}" ]] && (( ! ${LIBRARY_FOLDERS[(Ie)$f]} )); then
                all_reason="$cfile ($rf uses $tok; App/$f has no route mapping)"; return
            fi
            visited[$rf]=1
            # Followed further: a library file (DesignSystem, Shared: no screen of its own) and a file
            # in the changed file's own folder (a helper its own views use, which other folders embed).
            if (( ${LIBRARY_FOLDERS[(Ie)$f]} )) || [[ "$f" == "$folder" ]]; then next+=("$rf"); fi
            [[ -n "${FOLDER_ROUTES[$f]-}" ]] && folders[$f]=1
            print -r -- "    $tok <- $rf"
        done < "$SELECT_TMP/refs"
        [[ -n "$all_reason" ]] && return
        wave=("${next[@]}")
        (( ${#wave} )) || break
        declared=("${(@f)$(names_declared_in "${wave[@]}")}")
        split_declared "${declared[@]}"
        (( ${#names} + ${#members} )) || break
    done

    # The snapshot harness: the routes that use the names, helpers followed to the routes that call them.
    local -a fragments=() helper_names=("${(@k)snapnames}") helper_members=("${(@k)snapmembers}") helper_calls=()
    local -a searched=() new_names=() new_members=() new_calls=()
    local -A helpers_seen=() found=()
    local where kind value h
    local -a route_files=(App/Snapshots/*.swift(N))
    route_files=("${(@)route_files:#*/(${(j:|:)~HARNESS_MACHINERY}|${(j:|:)~HARNESS_PERF})}")
    while (( ${#helper_names} + ${#helper_members} + ${#helper_calls} )); do
        searched=("${helper_names[@]}" "${helper_members[@]}" "${helper_calls[@]}")
        found=() new_names=() new_members=() new_calls=()
        awk -v names="${(j: :)helper_names}" -v members="${(j: :)helper_members}" -v calls="${(j: :)helper_calls}" \
            "$SNAP_AWK" "${route_files[@]}" > "$SELECT_TMP/snap"
        while IFS=$'\t' read -r where kind value tok; do
            found[$tok]=1
            case "$kind" in
                ROUTE|ROUTES) fragments+=("${(@s:,:)value}"); print -r -- "    $tok <- $where (route $value)" ;;
                HELPER)
                    print -r -- "    $tok <- $where (helper $value)"
                    (( ${+helpers_seen[$value]} )) && continue
                    helpers_seen[$value]=1
                    case "${value%%:*}" in
                        type) new_names+=("${value#*:}") ;;
                        var) new_members+=("${value#*:}") ;;
                        *) new_calls+=("${value#*:}") ;;
                    esac ;;
                ALL) all_reason="$cfile ($where uses $tok: $value)"; return ;;
            esac
        done < "$SELECT_TMP/snap"
        [[ -n "$all_reason" ]] && return
        for h in "${searched[@]}"; do
            (( ${+found[$h]} )) || { all_reason="$cfile (the snapshot harness uses $h, and no route of it reaches $h)"; return; }
        done
        helper_names=("${(@u)new_names}") helper_members=("${(@u)new_members}") helper_calls=("${(@u)new_calls}")
    done

    local -a routes=()
    for f in "${(@ko)folders}"; do routes+=("${(@s:,:)FOLDER_ROUTES[$f]}"); done
    routes+=("${fragments[@]}")
    routes=("${(@u)routes}")
    print -r -- "    -> folders: ${(j: :)${(@ko)folders}}; routes: ${(j:,:)routes}"
    want+=("${routes[@]}")
}

# ALL, NONE, SCAN (a file under App/<Folder>/: select_for_app_file) for a changed path.
routes_for_file() {
    case "$1" in
        App/DesignSystem/*|App/Shared/*|App/Snapshots/*|App/Assets.xcassets/*|Sources/*|Config/*) echo ALL ;;
        project.yml|Package.swift|Package.resolved|scripts/render-snapshots.sh) echo ALL ;;
        App/*/*) echo SCAN ;;
        App/*) echo ALL ;;    # the app shell: ContentView, BudgetApp, AppEnvironment, LaunchView, Info.plist, entitlements
        Tools/*|Tests/*|docs/*|Phone/*|.superpowers/*|*.md|scripts/*) echo NONE ;;
        *) echo ALL ;;
    esac
}

# Prints the selection for these changed paths against $1 (the base ref); sets ONLY_FROM_SELECTION
# ("" with SELECTION=ALL or NONE).
select_routes() {
    local base="$1"; shift
    local -a want=()
    local all_reason="" r f
    SELECT_TMP="$(mktemp -d)"
    for f in "$@"; do
        r="$(routes_for_file "$f")"
        case "$r" in
            NONE) print -r -- "  $f -> nothing" ;;
            ALL) all_reason="$f"; break ;;
            SCAN) select_for_app_file "$f" "$base"; [[ -n "$all_reason" ]] && break ;;
        esac
    done
    rm -rf "$SELECT_TMP"
    ONLY_FROM_SELECTION=""
    if [[ -n "$all_reason" ]]; then
        SELECTION=ALL
        print -r -- "  $all_reason affects every screen (or can't be placed): rendering ALL routes"
    elif (( ${#want} == 0 )); then
        SELECTION=NONE
        print -r -- "  No changed file can affect a route: nothing to render."
    else
        SELECTION=SOME
        ONLY_FROM_SELECTION="${(j:,:)${(@u)want}}"
        print -r -- "  Rendering routes containing: $ONLY_FROM_SELECTION"
    fi
}

# --self-test: the --changed selection on files whose uses are known (from the repository; builds nothing).
if [[ "${1:-}" == --self-test ]]; then
    cd "$(dirname "$0")/.."
    failed=0
    # $1 base, $2 changed file, then ALL, NONE, or route names that must be selected (a selected
    # fragment contained in each, as --only matches).
    expect() {
        local base="$1" file="$2"; shift 2
        local -a fragments route_names=("$@")
        print -r -- "--changed for $file (base ${base[1,10]}):"
        select_routes "$base" "$file"
        if [[ "$1" == ALL || "$1" == NONE ]]; then
            [[ "$SELECTION" == "$1" ]] || { print -r -- "FAIL: expected $1, got $SELECTION"; failed=1; }
            return
        fi
        [[ "$SELECTION" == SOME ]] || { print -r -- "FAIL: expected a selection, got $SELECTION"; failed=1; return; }
        fragments=("${(@s:,:)ONLY_FROM_SELECTION}")
        local route fragment covered
        for route in "${route_names[@]}"; do
            covered=0
            for fragment in "${fragments[@]}"; do [[ "$route" == *"$fragment"* ]] && { covered=1; break; }; done
            (( covered )) || { print -r -- "FAIL: route $route not selected"; failed=1; }
        done
    }
    # A Dashboard file whose type Accounts, Forecast, Documents and Property (TwoUpRow, via the
    # DesignSystem's YearCard and MultiYearColumns) use.
    expect HEAD App/Dashboard/DashboardFormat.swift accounts-main accounts-euro_current forecast-compare forecast-grid \
        documents-main property-overview dashboard-main
    # An Import view drawn on the Dashboard.
    expect HEAD App/Import/NonGBPImportCaption.swift dashboard-main imports-history
    # A Documents file the app shell uses (TransactionDocumentCounts).
    expect HEAD App/Documents/EvidenceSupport.swift ALL
    # Budget's plan editing, which Forecast embeds.
    expect HEAD App/Budget/PlannedItemSheets.swift budget-main forecast-grid
    # A Tax model the gallery and the harness's helpers (context.taxYear, taxModel) use.
    expect HEAD App/Tax/TaxYearsViewModel.swift tax_years-accounts gallery-components sheet-tax_rate imports-review_p60
    # A deleted file (read at the base): its folder's routes.
    expect 33cc16a^ App/Budget/GridDrillDownSheet.swift budget-main
    # The shell, a file nothing can read, a tool, a test.
    expect HEAD App/ContentView.swift ALL
    expect HEAD App/Dashboard/NoSuchFile.swift ALL
    expect HEAD Tools/Sources/ImportDryRun/main.swift NONE
    expect HEAD Tools/Package.resolved NONE
    expect HEAD Tests/BudgetCoreTests/ToolDatabaseTests.swift NONE
    (( failed )) && { echo "render-snapshots self-test FAILED" >&2; exit 1; }
    echo "render-snapshots self-test OK"
    exit 0
fi

if [[ $# -lt 1 || "$1" == -* ]]; then
    echo "usage: $0 <outDir> [--quick] [--routes a,b] [--changed [base-ref]] [--only a,b] [--themes ids] [--appearances light,dark] [--looks light-classic,dark-midnight] [--scale n] [--as-of YYYY-MM-DD] [--size WxH]" >&2
    echo "       $0 --self-test" >&2
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
        # --no-renames: a moved file counts at its old path (deleted) and its new one.
        changed_files=("${(@f)$( { git diff --name-only --no-renames "$CHANGED_BASE"; git ls-files -o --exclude-standard; } | sort -u)}")
        changed_files=("${(@)changed_files:#}")
        echo "Routes: --changed since ${CHANGED_BASE[1,10]} (${#changed_files} changed files)"
        select_routes "$CHANGED_BASE" "${changed_files[@]}"
        [[ "$SELECTION" == NONE ]] && exit 0
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
