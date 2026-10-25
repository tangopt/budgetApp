# Step 5 (codebase optimisation), step 1: measurements

Measured 2026-10-25 on main at 856abf1, in a detached scratch worktree (since removed). No repo files were changed and nothing was committed.

**Machine:** Apple M1, 8 cores (4 performance + 4 efficiency), 16 GB. Xcode 27.1, Swift 6.4 (swift-driver 1.168.6), XcodeGen 2.46.0.

**Size:** BudgetCore is one module: 306 files, 72.8k lines. App: 182 files, 48.3k lines. MangoUI: 54 files, 5.9k lines. Phone: 10 files, 1.2k lines. BudgetDemo: 1.7k lines. There are 30 one-off tool executables, about 4k lines in total. Tests: 271 files, 67.9k lines, 3,357 tests.

**Targets:** a fix round under 5 min, the full test suite under 4 min, an everyday install under 2 min.

| Target | Today | Status |
|---|---|---|
| Full test suite | 226 s (`--parallel`) | met, with little room to spare (serial: 699 s) |
| Fix round | about 4.5–5 min (tests + an edit + a Debug app build), without snapshots | borderline |
| Everyday install | about 7.2 min (archive 417–420 s + export 3 s + copy) | missed by about 3.5× |

---

## 1. Builds

### swift build

| Case | Wall time |
|---|---|
| Clean `swift build` (all products, including the 30 tools); GRDB from cache | 59.7 s |
| First clean build of the session; CPU time (wall time wasn't captured) | user 301 s, sys 39 s |
| Clean `swift build --target BudgetCore` | 36.9 s |
| Then `--build-tests` on top | 48.1 s |
| Clean `swift build --build-tests` (what `swift test` needs) | 80.8 s |
| No-op | 2.0–3.0 s |
| Touch one BudgetCore file (`Tax/TaxDataPlan.swift`) | 7.8 s |
| Touch another BudgetCore file (Money) | 7.7 s |
| Edit one BudgetCore file: add an internal declaration, so the module interface changes | 28.1 s; reverting it took another 28.1 s |
| `--build-tests` no-op | 2.0 s |
| `--build-tests` after touching one BudgetCore file | 9.1 s |

The 28 s edit case is the one that matters in a fix round. When BudgetCore's interface changes, everything that depends on it recompiles and relinks: MangoSync, MangoUI, BudgetDemo, all 30 tool executables and the test bundles.

### App with xcodebuild, Debug, arm64, own DerivedData

| Case | Wall time |
|---|---|
| Cold | 81.4 s |
| No-op | 3.1 s |
| Touch `App/ContentView.swift` | 9.6 s |
| Edit `App/ContentView.swift` | 9.4 s |
| Touch a BudgetCore file | 15.4 s |
| Edit a BudgetCore file (internal declaration) | 31.0 s |
| `xcodegen generate` | 0.1 s |

## 2. Tests

| Run | Wall time |
|---|---|
| `swift test` (serial) | 699 s. XCTest reports 655.6 s. 3,357 tests, 4 skipped, 0 failures. |
| `swift test --parallel` (8 workers) | 226 s. The per-test times add up to 1,775 s, so about 7.9 workers stay busy the whole run. |
| `swift test --parallel --num-workers 4` | 310 s |

The parallel run is limited by total CPU, not by its slowest test, so cutting CPU per test shortens the wall time almost one-for-one.

**Spread of test times (serial):**
- Median 115 ms, 90th percentile 250 ms.
- 1,213 tests take under 20 ms, about 1 s in total.
- 1,639 tests fall between 100 and 200 ms, 212 s in total. That 100 ms floor is the database migration.
- 103 tests take over 1 s, 351 s in total. 8 tests take over 10 s, 152 s in total.

### Database creation cost

I counted every database creation in a full parallel run, using temporary timing code in the scratch worktree only.

| Item | Per call | Calls per run | Total (serial) |
|---|---|---|---|
| `DatabaseManager.migrate()`: migrations + sync triggers | 112 ms | 2,442 | about 273 s (40% of the serial run) |
| `DemoDatabase.build`, on top of its migration | about 1.4 s | 91 | about 127 s (18%) |

- `refreshSyncTriggers` is 37% of each migration's cost.
- In the parallel run, migrations used 443 s of the 1,775 CPU-seconds (25%) and demo builds 198 s (11%).
- Copying an already-migrated template database with SQLite's backup API takes 0.3 ms. Copying a built demo database takes 0.6 ms.
- About 240 tests call `DatabaseManager(path: nil)` directly, and there are 18 copies of a private `makeDB()`, plus `makeFixture`, `migrated` and similar helpers. Every one of them migrates from scratch.

### Slowest test classes (serial seconds, number of tests)

| Class | Time | Tests | Notes |
|---|---|---|---|
| ImportRehearsalTests | 56.3 s | 2 | |
| ImportSessionTests | 39.8 s | 8 | builds the demo database in `setUp` |
| DemoImportKindsScenarioTests | 33.5 s | 5 | |
| FiledYearSyncCheckTests | 30.8 s | 21 | |
| FiledYearEditCheckTests | 28.1 s | 19 | |
| SyncRehearsalTests | 24.6 s | 8 | |
| FiledYearGuardTests | 23.8 s | 39 | |
| DemoDatabaseTests | 22.5 s | 10 | |
| SyncTranslatorTests | 14.3 s | 22 | |
| SyncBatchTests | 13.9 s | 14 | |
| ImportDryRunTests | 11.8 s | 1 | |
| HomeSummaryTests | 10.9 s | 6 | |
| DemoImportSamplesTests | 10.6 s | 1 | |
| SyncEngineCoreTests | 10.5 s | 31 | |
| HomeTests | 10.3 s | 14 | |
| PropertyTests | 9.8 s | 12 | |
| RentalAccountsTests | 8.5 s | 48 | |
| PropertyGlanceTests | 8.1 s | 5 | |
| SyncConflictTests | 8.0 s | 22 | |
| ImportApplierTests | 7.9 s | 31 | |

By target: BudgetCoreTests 655.5 s, MangoUITests 35.2 s, MangoSyncTests about 0 s.

### Slowest tests (serial seconds; parallel times run 1.5–3× higher)

| Time | Test |
|---|---|
| 55.73 s | ImportRehearsalTests.testRehearsalOverTheDemoDatabaseAndLibrary (85.7 s in the parallel run) |
| 27.98 s | ImportSessionTests.testPlanAnswerConfirmUndoRoundTrip |
| 12.43 s | SyncRehearsalTests.testRehearsalOnThePreSyncDemo |
| 12.12 s | SyncRehearsalTests.testWithoutALibraryDocumentsGoWithoutFiles |
| 11.79 s | ImportDryRunTests.testDryRunOverTheDemoDatabase |
| 11.28 s | FiledYearEditCheckTests.testEachScopeHelperCoversWhatItsWriteTouches |
| 10.60 s | DemoImportSamplesTests.testDemoSamplesProduceEachSection |
| 10.52 s | ImportSessionTests.testStagesReportedInOrder |
| 8.96 s | DemoImportKindsScenarioTests.testTheInstalmentPairIsAskedThenKeptOnBothDebits |
| 8.28 s | SyncTranslatorTests.testEveryColumnRoundTrips |
| 8.27 s | DemoImportKindsScenarioTests.testTheThreeDocumentsOfOneDebitImportWithoutAnAlert |
| 8.23 s | DemoImportKindsScenarioTests.testTheUnknownFileIsSetAsideKeptAndSuggestedAgainOnceItsKindExists |
| 6.46 s | DemoImportKindsScenarioTests.testTheStampDutyNoteLinksToItsDebit |
| 4.49 s | SyncBatchTests.testADeviceThatJoinsLaterNeverHoldsPartOfABatch |
| 3.97 s | SyncBatchTests.testPartialManifestNeverApplies |
| 3.58 s | DemoDatabaseTests.testAFileDatabaseIsMarkedAsTheDemo |
| 3.52 s | AppDataGuardTests.testRechargeDetailsReconcile |
| 3.41 s | FiledYearGuardTests.testTheShortcutHoldsAndExplainsExactlyWhatTakingEveryFigureDoes |
| 3.39 s | DemoDatabaseTests.testLongTenancyForTiming |
| 3.21 s | SourceFolderScannerTests.testScansThousandsOfFiles |
| 3.16 s | DemoDatabaseTests.testIsDeterministic |
| 2.96 s | DemoDatabaseTests.testSelfAssessmentComputes |
| 2.59 s | FiledYearSyncCheckTests.testAnEarlierYearsLossCarriedIntoTheFiledYearIsCaught |
| 2.56 s | HomeSummaryTests.testFreshnessIsAmberAfter14Days |
| 2.46 s | FiledYearSyncCheckTests.testAHeldBatchCountsOnceTowardsTheCap |
| 2.12 s | BBVAEarlierHistoryImportTests.testPaidYearsAreGuardedAndAFiledReturnFigureCanBeReached |
| 1.91 s | FiledYearGuardTests.testAnnotateReplacesEarlierGuardAnnotations |
| 1.86 s | FiledYearEditCheckTests.testSeveralPeopleAreNamedOnTheirLines |
| 1.86 s | FiledYearSyncCheckTests.testAChangeToA2021FigureIsHeldThoughThatYearIsNotStoredFiled |
| 1.83 s | FiledYearSyncCheckTests.testOnlyTheRecordsThatWouldMoveAFiledFigureAreHeld |
| 1.82 s | HomeTests.testTheDemoNetWorthIsTheAccountsOverviewsNetWorth |
| 1.82 s | HomeSummaryTests.testHomeLeftToSpendEqualsTheMacDashboard |
| 1.82 s | HomeTests.testFreshnessNamesTheLastDayAndTurnsAmberPastFourteenDays |
| 1.80 s | PayMonthReviewTests.testReviewRowsEqualTheBudgetGrid |
| 1.79 s | FiledYearSyncCheckTests.testARecordThatWaitedForTheHouseholdKeyIsCheckedWhenItOpens |
| 1.76 s | HomeSummaryTests.testUpcomingMergesBillsAndObligationsByDate |
| 1.74 s | PropertyGlanceTests.testRentExpectedThenLate |
| 1.71 s | HomeSummaryTests.testHomeUsesTheInputsToday |
| 1.70 s | DemoDatabaseTests.testRentalAccountsHaveNoDataWarnings |
| 1.69 s | MortgageHistoryTests.testTheDemoLoanIsEstimatedFromItsStart |

The FiledYear* classes spend most of their time in `TaxFigures.snapshot` (see section 6).

### Tests per file (largest)

| Tests | File |
|---|---|
| 52 | ImportDuplicatesTests |
| 48 | RentalAccountsTests |
| 43 | EvidenceLibraryTests |
| 41 | MissingEvidenceTests |
| 40 | SyncEngineCoreTests |
| 39 | FiledYearGuardTests |
| 38 | ImportPipelineTests |
| 38 | RechargeTests |
| 37 | PlannedItemEditingTests |
| 36 | ImportLearningTests |
| 35 | BBVAStatementReaderTests |
| 35 | IssuerKeyTests |
| 35 | ScenarioApplyTests |
| 34 | DocumentImportReadersTests |
| 31 | ImportApplierTests |
| 31 | ScenariosTests |
| 31 | SearchTests (MangoUI) |
| 30 | SyncChangeTrackerTests |
| 30 | TransactionSearchTests |
| 30 | TransferCategoriesTests |
| 30 | TransferMatcherTests |
| 30 | UtilityInvoiceIntakeTests |

The full per-file list is in the inventory output (`inventory.sh` in the scratchpad).

## 3. Snapshots (`scripts/render-snapshots.sh`, full run)

- **Cold full run: 1,144 s (19 min).** It rendered 912 PNGs: 153 routes in 2 appearances and 3 themes. The wrap probe found 0 violations.
  - Build: about 140 s (the Debug snapshot build, about 80 s, plus a cold `swift build` of MakeDemoDatabase and the demo database).
  - Rendering: 1,002 s over 151 timed routes, about 6.6 s per route, or about 1.1 s per PNG.
- **Warm run:** I stopped it partway to save time. The estimate is about 17 min, since only the build part gets shorter.
- **Rendering time by group:**

| Group | Time | Notes |
|---|---|---|
| imports-* | 344 s | 15–21 s per route; each look seems to rerun the import review |
| sheet-* | 262 s | |
| property | 98 s | |
| tax | 71 s | |
| auth | 59 s | |
| budget | 24 s | |
| rules | 21 s | |
| settings | 20 s | |
| documents | 19 s | |
| forecast | 18 s | |

- **Slowest routes:**
  - imports-review_model_checked: 20.7 s
  - imports-history: 20.2 s
  - imports-review_model_all_checked: 18.5 s
  - budget-transaction-documents: 17.5 s

## 4. Install path

`scripts/install-app.sh` archives with the team. I timed the same `xcodebuild … -configuration Release archive` into scratch DerivedData.

| Case | Wall time |
|---|---|
| Archive, cold | 460.2 s |
| **Archive, warm, nothing changed** | **420.1 s** |
| Archive, warm, one App file touched | 418.1 s |
| Archive, warm, one BudgetCore file touched | 417.1 s |
| Export (developer-id) | 2.8 s, cheap |
| Archive arm64-only (`ARCHS=arm64`), warm DerivedData | 343.2 s |

**The archive step is never incremental.** Every run recompiles everything with whole-module optimisation (WMO), GRDB included, and builds two architectures (x86_64 and arm64; the app comes out universal).

**Everyday install today:** about 420 s + 3 s export + ditto/lsregister, so **about 7.2 min**.

Alternatives I measured (Release, arm64, persistent DerivedData):

| Case | `build` | `build` with `SWIFT_COMPILATION_MODE=singlefile` |
|---|---|---|
| Cold | 365.7 s | 322.1 s |
| No change | 3.3 s | not measured |
| Touch an App file | 77.2 s (the App module recompiles whole) | **9.3 s** |
| Touch a BudgetCore file | 191.9 s | 190.6 s |
| Edit a BudgetCore file | not measured | 236.3 s |

- The `build` output is signed with Apple Development. It would still need the Developer ID signing or export step; export takes about 3 s.
- The setting on the right helps only the App target. **Xcode still compiles the BudgetCore package with `-whole-module-optimization` in Release**, so a BudgetCore change costs about 3–4 min.

Projected everyday install with an incremental arm64 Release build plus export:
- App-only change: about 15–90 s.
- BudgetCore change: about 3.3–4 min, until BudgetCore's Release compile gets cheaper (split it into modules, or drop WMO for local installs).

## 5. iPhone (MangoPhone, Debug, generic iOS Simulator)

| Case | Wall time |
|---|---|
| Cold | 73.0 s |
| No-op | 3.1 s |
| Touch a Phone file | 4.9 s |
| Touch a MangoUI file | 4.0 s |

## 6. `TaxFigures.snapshot` on the real database (read-only copy)

I profiled on a read-only copy of the real database, which I have since deleted. Only timings and query shapes were looked at, no personal data.

### Timings

| Build | All years | Latest year only | Earliest year only |
|---|---|---|---|
| Release | 493 ms | 494 ms | 27 ms |
| Debug | 1,446 ms | 1,423 ms | 98 ms |

Cost of one year in Release, by position from the earliest: 26, 61, 95, 131, 173, 215, 270, 340, 418, 495 ms. It grows steadily from earliest to latest.

### Why one year costs the same as ten

`SelfAssessment.compute(year)` calls `compute(year − 1)` for the brought-forward losses and finance costs, all the way back to the earliest year with rules. Each year's return runs `RentalAccounts.compute` for each person and property.

- So the latest year alone does a RentalAccounts run for every earlier year and person, about 25–37 ms each in Release.
- `TaxComputationMemo` lives only for one `snapshot` call, so every snapshot starts over.

### SQL is not the main cost

| | All years | One year |
|---|---|---|
| Statements | 5,210 | 5,191 |
| Time inside SQLite | 0.139 s | 0.143 s |
| Share of the Debug run | about 10% | about 10% |

The rest is CPU in Swift.

### Hot spots (CPU sample of the Debug build looping `snapshot`, inclusive time)

1. **`Recharges.received`: 33%. A classic N+1 query pattern.**
   - It loads the IDs of every recharge payment of the property, with no date filter.
   - For each one it then runs 3 separate `fetchOne(key:)` calls: RechargePayment, Transaction, RechargeStatement.
   - The date-window filter is applied in Swift afterwards.
   - Total per snapshot: 3 × 1,020 single-row lookups.
   - The fix is one JOIN with the date window in SQL.
2. **Building GRDB statements for `fetchOne(key:)` and other query-interface calls: 43% overall, overlapping the other items.**
   - Schema lookups (`SchemaInfo.containsObjectNamed`): 17%.
   - sqlite3 prepare: 15%.
   - StatementAuthorizer: 13%.
   - These are uncached, one-row statements: 1,020 × 3 above, 560 `taxYearSplit`, 522 `taxAttributionRule`, 172 `propertyOwner`.
   - Fix: preload rules and splits once per snapshot, or use cached SQL statements.
3. **`RentalAccounts.linkedDocuments`: 25%.**
   - It decodes EvidenceDocument rows by column name, 98 calls per snapshot.
   - Each year reads transactions in a window from 3 years before to 3 years after, so about 7 years of transactions and their documents.
   - Over all the years that is roughly 7× more reading and decoding than needed.
   - Fix: load once per snapshot and slice per year.
4. **`RentalAccounts.month()` and `monthsLabel()`: about 16%.** They create a new `DateFormatter` on every call, for warning text built on every run. A static formatter, or building the text lazily, fixes it.
5. **`TaxSplits.share`: 7%. `TaxAttributionRules.effective`: 4%.** Both are per-type lookups repeated for every year, person and property.

**Expected outcome:** fixing items 1–4, and sharing one preload across years, should bring `snapshot` from about 0.5 s to roughly 0.1 s in Release. That would also shorten the FiledYear* tests, about 82 s serial.

Optional further step: keep the memo across snapshots while the database hasn't changed (for example keyed by `PRAGMA data_version` plus a write counter).

## 7. Possible duplicate or overlapping tests (for your review; nothing removed)

I compared test bodies by token similarity (Jaccard of 4-token sequences ≥ 0.6, 44 pairs) and test names. Most similar pairs are deliberate variants of the same case. The ones worth a look:

- **Same test name in several MangoUI classes:** `testAFailedReadKeepsThePageAndAFirstFailureShowsTheFixedSentence` and `testAReloadWaitsForANewSync` (Property, Month, Accounts); `testAnEmptyDatabaseIsTheEmptyState` (Home, Accounts); `testATransactionsAmountTakesItsCategorysRole` (Month, Accounts). Each checks the same loading behaviour on a different view model. They could become one parameterised test over the view models, if the loading code is shared. If it isn't shared, keep them.
- **Plain insert-and-fetch tests:** `CategoryTests.testInsertAndFetchCategory`, `CategoryGroupTests.testInsertAndFetchCategoryGroup` and `RuleTests.testInsertAndFetchRule`. These only round-trip a GRDB record; the service tests (CategoriesTests, CategoryGroupsTests, RulesTests) cover the same paths and more. Each costs about 115 ms, almost all of it the migration.
- **Pairs that may be subsets of each other:**
  - `MerchantKeyTests.testShortKeyFallsBackToFullDescription` and `RuleLearnerTests.testShortKeyFallsBackToFullUppercasedDescription`.
  - `ImportModelTests.testFiledYearHoldsTakeOnlyLeaveOut` and `ImportPipelineTests.testFiledYearHoldsOnlyLeaveOut`: the same behaviour at the model and pipeline levels.
  - `DocumentImportReadersTests.testTwoRecordedInvoicesFittingAskWhichOne` and `ImportApplierTests.testTwoRecordedInvoicesFittingAskWhichOneThenAttach`: the second probably includes the first.
  - `BBVAStatementReaderTests.testClosingMismatchIsNeedsYou` and `UKStatementReaderTests.testClosingBalanceMismatchIsNeedsYou`: different readers, so probably keep both.
  - `HomeTests.testTheSameSyncDoesNotReloadAgain` and `SearchTests.testAReloadForTheSameSyncDoesNotReadAgain`: the same reload-guard pattern again.
- **Near-identical bodies within one class (good candidates to merge into a parameterised or table-driven test, not to delete):**
  - CustomDocumentKindMergeSyncTests: merge into a built-in kind / a custom kind, document filed before or after (0.84–0.87 similar).
  - TransactionFingerprintTests: same, different amount, different account, normalisation (0.61–0.80).
  - TouchIDAutoPromptTests: 5 small scenario tests (0.60–0.83).
  - CSVStatementParserTests: debit/credit column variants (0.60–0.75).
  - StatementBalanceExtractorTests: file order vs reversed file order (0.76).
  - FrequencyExpanderTests and CoverWindowPolicyTests: pairs at 0.61–0.64.

  Merging these saves almost no time unless they create databases (CustomDocumentKind tests do). The gain is mainly readability.
- **The real time cost is repeated heavy setup, not duplication:**
  - ImportSessionTests builds the demo database in `setUp` for all 8 tests.
  - DemoImportKindsScenarioTests (5 tests) and SyncRehearsalTests (8) do something similar.
  - Of 91 demo builds per run, most produce the same database.
  - ImportRehearsal, ImportDryRun, SyncRehearsal and DemoImportSamples all run end-to-end over a fresh demo database, so they overlap.

## 8. Code hotspots

**Largest files (lines):**
- ImportPipeline.swift: 1,740
- BBVAEarlierHistoryImport.swift: 1,297
- BudgetGridView.swift: 1,204
- SnapshotCatalog.swift: 1,183
- TaxDataPlan.swift: 1,175
- DemoDatabase.swift: 1,174
- RentalAccounts.swift: 1,093
- RechargeSheets.swift: 1,073
- ImportModel.swift: 1,059
- BudgetGridViewModel.swift: 1,018
- SelfAssessment.swift: 1,011
- ImportDuplicates.swift: 1,010

**Largest functions (lines):**
- `BBVAEarlierHistoryImport.apply`: 497
- `RentalAccounts.compute`: 469. This is also the runtime hotspot in section 6.
- `SelfAssessment.calculate`: 387
- `ImportPreviewPanel.body`: 277
- `ImportResolutions.apply`: 266
- `DocumentImportReaders.item(file:recognition:context:)`: 253, with sibling `item` functions of 145 and 127 lines in the same file. They look duplicated.
- `BudgetGridView.body`: 251
- `ImportReviewDemo.make`: 239
- `BBVAFundMortgageImport.apply`: 193
- `ContentView.body`: 188

**Duplication and structural issues:**
- **Test database helpers:** 18 private copies of `makeDB()`, 5 copies of `emptyDatabase()`/`demoDatabase()` in MangoUITests, and many `makeFixture`, `migrated` and `makeManager` variants. Replacing them with one shared `TestDatabase.migrated()` / `TestDatabase.demo()` that copies a template is opportunity B below.
- **DateFormatter:** 49 `DateFormatter()` call sites; about 20 in BudgetCore create one on every call. Examples: `TransactionFingerprint.compute` (once per imported row), `RentalAccounts.month`, `ScenarioApply`, `CSVStatementParser`, `BalanceConversion`, `SelfAssessment`.
- **Single-row lookups:** 247 `fetchOne(db, key:)` calls in BudgetCore, about 46 of them inside loops (possible N+1 patterns). `Recharges.received` is a confirmed one.
- **One big BudgetCore module (73k lines):**
  - Release WMO compile is about 190 s, which gates any install that touches BudgetCore.
  - When its interface changes, the 30 tool executables relink in every plain `swift build` (28 s).
  - Splitting it into roughly four modules would allow parallel WMO and cheaper rebuilds. Candidates: Core models/DB, Tax/Property, Import/DocumentImport/Evidence, Sync.
  - Moving the tools to a separate package or product would also help.

---

## Opportunities, ranked by time saved

**A. Install: build incrementally instead of archiving every time (saves about 5–6 min per install).**
- Today `archive` rebuilds everything, for two architectures, with WMO: 417–420 s even when nothing changed.
- Instead: an arm64 Release `build` in the persistent cache, with the App target incremental, then Developer ID signing via export (3 s).
- Measured: an App-only change takes 9–77 s; a BudgetCore change about 190 s.
- Keep the universal archive for `--notarise` and distribution builds.

**B. Tests: copy a migrated template database (saves about 270 s serial; about 36% of the parallel CPU together with the demo copy).**
- 2,442 migrations per run at 112 ms each, versus a 0.3 ms backup copy.
- 91 demo builds at about 1.4 s each, versus a 0.6 ms copy of a demo database built once per process.
- Projected: `swift test --parallel` from 226 s to about 140–150 s; serial from 699 s to about 300 s.

**C. Snapshots: render less per fix round (saves about 15 min per run).**
- A full run is 19 min.
- Default fix rounds to one look (light-classic) and only the changed routes: about 6× less rendering.
- Cache the import-review plan per route; the 344 s of imports routes appear to rerun the import for each look.

**D. BudgetCore Release compile (about 190 s).**
- This is what keeps a BudgetCore-touching install above 2 min, even after A.
- Split BudgetCore into modules (parallel WMO), or compile it without WMO for local installs.
- Also take the 30 tools out of the default `swift build`; a BudgetCore interface edit costs 28 s today.

**E. Slowest tests and `TaxFigures.snapshot`.**
- After B, the 56 s ImportRehearsal test (86 s under parallel load) becomes the floor on parallel wall time. Start it first, shrink it, or split it.
- ImportSession, DemoImportKinds and SyncRehearsal add about 100 s serial of mostly repeated demo setup.
- Fixing the `TaxFigures.snapshot` hot spots (section 6) takes it from 0.5 s to about 0.1 s in the app and speeds up the FiledYear* tests (82 s serial).

---

## After (2026-10-25)

Measured on branch `optimise` at c79ae38, same machine, scratch build folders, one measurement at a time. The 1-minute load average was under 4 (3.5–3.97) just before each timing; the load shown by `uptime` during a run is the run's own. Nothing outside scratch folders was touched (installs used `--output`).

| Measure | Before | After | Target |
|---|---|---|---|
| Full suite, `swift test --parallel` (wall) | 226 s | **118.5 s** and **124.2 s** (CPU user 646 s / 642 s, sys 110 s; was 1,775 s of test time) | under 4 min (aim ~2.5): met |
| Test count | 3,357 | 3,344 (duplicates removed), no failure lines in either run | |
| Everyday install, nothing changed | about 420 s | **5.6 s** | under 2 min: met |
| Install, one App file touched | about 418 s | **12.0 s** | met |
| Install, one BudgetCore file touched | about 417 s | **15.4 s** (touch only, no interface change) | met |
| Install, first run into an empty output folder | 460 s cold | 166.7 s (arm64 Release build into the shared cache) | n/a (one-off) |
| Fix round: 1 test class + Debug app build + 2-route quick snapshot | about 4.5–5 min without snapshots | **about 2.2 min** (44 s `swift test --filter FiledYearGuardTests` + 28 s incremental app build + 56 s snapshot, which does its own build); 3.0 min as run in one go with a cold app build folder (44 + 78 + 56) | under 5 min: met |
| `TaxFigures.snapshot` (the real database, read-only copy, Release) | 501 ms | 118 ms (Task 4) | at most 0.15 s: met |
| Clean `swift build` | 59.7 s | 46.5 s | |
| `swift build` no-op | 2.0–3.0 s | 1.5 s | |
| Touch one BudgetCore file | 7.8 s | 8.8 s | |
| BudgetCore interface edit (add a public func) | 28.1 s | 17.5 s | |
| Revert that edit | 28.1 s | 16.1 s | |
| Quick snapshot, `--routes dashboard-main,sheet-owners` | not available (full run 1,144 s, about 6.6 s per route) | 40 s including build; 3 PNGs (the sheet has an error variant), about 3 s each | |
| Quick snapshot, `--changed HEAD` with `App/Accounts/AccountFormSheets.swift` edited | not available | 177 s for 53 routes (selected: `accounts`, `sheet-`, `imports-review_remap`), one look each | |

Notes:
- `--changed` with no argument diffs against the merge-base with main (cec8ab7), which on this branch is a large diff; I used `HEAD` as the base with one temporary edit to show a typical selection, and reverted it.
- The full parallel runs print no XCTest summary line, so the test and failure counts come from the `[n/3344]` progress lines and the absence of any failure lines; the snapshot wrap probe also reported 0 violations.
- The 28 s app build in the fix-round estimate is an incremental Debug build after a BudgetCore interface edit; the first build into a fresh DerivedData took 78 s.
- The full 16-minute snapshot run was not repeated.
