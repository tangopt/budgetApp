# Tools

One-off and maintenance executables (imports, data fixes, tax regressions, rehearsals). They live in this nested
package, which depends on the root package by path, so a plain `swift build` / `swift test` at the root doesn't
relink them every time BudgetCore changes.

Run one from the repository root:

    swift run --package-path Tools <Tool> [arguments]

Build them all with `swift build --package-path Tools`. Older plans and notes that say `swift run <Tool>` mean this
command now. `MakeDemoDatabase` stays in the root package (`swift run MakeDemoDatabase`), because
`scripts/render-snapshots.sh` builds it.

Tools open databases only through `ToolDatabase`; `ToolDatabaseTests` in the root package scans `Tools/Sources`.
