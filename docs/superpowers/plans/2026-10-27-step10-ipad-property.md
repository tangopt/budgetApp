# Step 10: iPad property redesign (absorbs "import on iPad") — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (chosen) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the member runs the flat's month on the iPad (check last month's rent, fetch bills from provider sites, charges into the grid, email the tenant) and gathers the tax year's evidence, with every Mac property capability reachable, redesigned touch-first.

**Architecture:**
- **BudgetCore owns the logic:** tray, saved sites, check-and-link proposals and saves, the This-month checklist (computed, never stored), the recharge email package, tax-year evidence grouping, the calendar grid. `MangoUI/Pad` only renders and calls them; the Mac keeps its views and gains nothing but shared BudgetCore code.
- **One way in for documents:** the built-in browser (WKWebView) captures PDFs into an app-private Downloads tray; the Check-and-link sheet reuses the Mac's import/check rules (`UtilityInvoiceIntake`, the statement readers and checks, `EvidenceLinkGuard`) and saves through `DeviceWriter.writeCheckingFiledYears`. Nothing syncs until a tray file is checked and saved.
- **One document panel, one button system, one sidebar** are built first (Tasks 2–4); every later screen is composed from them.

**Tech Stack:** Swift 6, SwiftUI, WebKit (`WKWebView`, `WKDownload`), MessageUI / share sheet, PDFKit, GRDB 6.29, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-27-ipad-property-redesign-design.md` (binding; mockups are private, the spec carries behaviour). Cited: `2026-10-26-ipad-tenancy-design.md` (step 8: `DeviceWriter`, inline refusals, Mac re-validates). Previous plan (style, commands): `2026-10-27-step7b-lean.md`.

## Global Constraints

- **Logic in BudgetCore** (`Sources/BudgetCore`). `Sources/MangoUI/Pad`, `Phone/` and `App/` call it. `scripts/build-core-ios.sh` stays green.
- **Writes** go through `DeviceWriter.writeCheckingFiledYears` (a question becomes an inline refusal via `PadRefusalBanner`/`DeviceWriteCopy`, nothing saved, nothing queued); the Mac re-validates. Never bypass it.
- **Permissions decide edit visibility: controls are hidden, not disabled** (`DeviceWriter.canEdit(.property)` / `.documents` / `.import`).
- **Fits 11" and 13" iPad, portrait and landscape.** Each UI task renders its routes with `scripts/render-phone-snapshots.sh $S10/snaps --device ipad --only <routes>` at the four sizes (11"/13" × portrait/landscape; Task 2 extends the harness with the size flag if it lacks one) and reports 0 wrap violations.
- **No figure wraps or truncates; names truncate in the middle** (`.lineLimit(1).truncationMode(.middle)`).
- **Edits save only on Save** or an explicit button. No edit saves on dismiss or on change.
- **Tenant's personal name appears only on Tenancies and in the recharge email;** everywhere else the tenancy's name.
- **Filed SA returns 2020/21–2024/25 never change.**
- **Tests never touch the real DB (`~/Library/Application Support/Budget`), the Keychain, iCloud, `/Applications` or real web sites.** Use `TestDatabase`, BudgetDemo, `FakeCloud`, `TwoPersonHousehold`, and local HTML/PDF fixtures (`Tests/TestSupport/Fixtures/web/`, served from a `file://` or an in-process `localhost` server). No subagent runs `scripts/install-app.sh`.
- **No passwords, cookies or session data are stored or synced by Mango.** The tray is app-private, `NSFileProtectionCompleteUntilFirstUserAuthentication`, excluded from backup, never synced.
- **No new CloudKit record type, except `savedSite` in Task 6** (the only place one is proved needed; see there). If Task 6 is dropped, none.
- **The Mac app is unchanged** except shared BudgetCore code; the Mac build and suite must stay green.
- **Nothing personal committed** (public repo): synthetic names, no real URLs of the household's accounts, no emails.
- **Build the App/Phone targets with `xcodebuild`** (`scripts/build-phone.sh`), not just `swift test`, for any task touching `Phone/`, `App/`, `project.yml`.
- **Commands** (`S10=/tmp/mango-10-build`, outside `~/Documents` because of iCloud CodeSign issues):
  - targeted: `swift test --scratch-path $S10 --filter '<Tests>'`
  - full suite, once at the end of each task: `swift test --scratch-path $S10 --parallel`
  - phone/iPad build: `scripts/build-phone.sh`
  - Mac build: `xcodegen generate && xcodebuild -project Mango.xcodeproj -scheme Mango -configuration Debug -derivedDataPath $S10/dd CODE_SIGNING_ALLOWED=NO build`
  - iPad snapshots: `scripts/render-phone-snapshots.sh $S10/snaps --device ipad --only <routes>`
  - `scripts/check-actor-writes.sh` → "actor writes OK" after any task adding a write path.
  - **at most 2 building agents at once.**
- **Model tags:** **[opus]** = privacy, sync, write path, filed year or import-check logic: most capable model plus a spec+code review. **[sonnet]** = UI: quick review.
- **Dropping tasks: drop from the end.** Order is by value. 16 and 15 (Checks, Profile, Money, Calendar) are Mac-only if dropped. Task 6 (synced saved sites) is independent: if dropped, sites stay device-local (Task 5's `LocalSavedSiteStore`). If Task 1 says no-go, follow its fallback; Tasks 7+ are unaffected (they consume `DownloadsTray`, not the browser).

## Review Focus

1. **A "download" that is not a PDF** (an HTML error page, a 0-byte file, a login redirect saved as `.pdf`) or the same PDF fetched twice. Expect the tray to refuse it with a plain message, and to keep one item per sha256. Task 5: `testNonPDFRefused`, `testSameHashKeptOnce`.
2. **A saved site that is not a safe web address** (`javascript:`, `file:`, `http:` without TLS, a lookalike host typed by hand). Expect only `https` accepted; the browser never loads anything else. Task 5: `testOnlyHTTPSAccepted`.
3. **Sign-out, leaving the household, or switching to demo with files in the tray.** Expect the tray emptied and the browser's website data cleared; nothing left on disk. Task 5: `testSignOutPurgesTrayAndWebsiteData`.
4. **A month with no tenancy yet, a first month with no "last month", two tenant transfers adding up to the recharge, or a bills grid with nothing expected.** Expect each checklist step to say so (not applicable / waiting), never an error or a false "done". Task 9.
5. **Mail not set up, tenant with no email address, or a statement with a missing PDF.** Expect Prepare email to fall back to the share sheet with the same attachments, name what's missing, and never mark the statement sent until the person confirms. Task 12.

---

### Task 1 [opus]: SPIKE — WKWebView sign-in and PDF capture in the iPad simulator

Throwaway: no merge, no tests shipped. Output is a findings note and a go/no-go the later tasks read.

**Files:**
- Create (throwaway, not committed): `/tmp/mango-10-spike/` scratch SwiftUI app (iPad), `/tmp/mango-10-spike/web/` local HTML with a username/password form and links to a PDF served `Content-Disposition: attachment`, a PDF served inline (`application/pdf`), and a redirect to an HTML error page.
- Create (committed): `docs/superpowers/plans/2026-10-27-step10-spike-findings.md`

**Questions to answer (each with evidence from the simulator):**
- [ ] **Step 1: AutoFill.** In a plain `WKWebView` (no associated-domains entitlement, no `webcredentials`), with a credential for the test host saved in the simulator's Settings ▸ Passwords, does tapping the password field offer it (QuickType bar / Passwords sheet)? Repeat with the entitlement `webcredentials:<test host>` added to see if it changes anything. Record: needed or not; what the simulator can and cannot prove (Face ID prompt, real iCloud Keychain) so the user's one real-device check is exact. *(Expected from Apple's docs: web-form AutoFill in `WKWebView` needs no entitlement; associated domains matter only for native fields. Verify, do not assume.)*
- [ ] **Step 2: WKDownload.** With `decidePolicyFor navigationResponse`, return `.download` for `application/pdf` (inline or attachment) and for `Content-Disposition: attachment`; `WKDownloadDelegate.decideDestinationUsing` writes into a temp directory, then the file is moved into a directory with `NSFileProtectionCompleteUntilFirstUserAuthentication` and `isExcludedFromBackup = true`. Confirm: attribute values read back; the HTML error page is not captured; a POST-triggered download (form submit, as providers do) is captured; a `blob:` or JS-generated PDF case — record whether it works (fallback: `WKWebView.createPDF` is not acceptable; note the limitation).
- [ ] **Step 3: Site data.** Confirm `WKWebsiteDataStore.default().removeData(ofTypes: all, modifiedSince: .distantPast)` clears cookies (needed by sign-out). Confirm `WKWebsiteDataStore.nonPersistent()` can be offered as "private browsing".
- [ ] **Step 4: Write the findings note** with: one table (question, result, evidence), the exact `WKWebView`/`WKDownload` code lines that worked (≤ 40 lines, as the reference Task 5 copies), and **GO / NO-GO**:
  - **GO** if Step 1 shows AutoFill offered with no entitlement (or with a plain `webcredentials` entitlement Task 5 then adds to `Phone/Mango.entitlements` and `project.yml`) AND Step 2 captures attachment and inline PDFs.
  - **NO-GO for the in-app browser** if AutoFill cannot work in-app, or downloads cannot be captured.
  - **Fallback if NO-GO (decided now so Task 5 can switch without re-planning):** "Open site" opens the saved URL in Safari (`UIApplication.open`, where Passwords AutoFill is native) and the file comes back into Mango through the share sheet (**Share ▸ Mango**, via `onOpenURL` / `.fileImporter`, plus a Files-picker button on the tray). `ASWebAuthenticationSession` is *not* the fallback for downloads (it cannot hand a PDF back) and is used only if a provider offers an OAuth sign-in, which none of the household's do. In that case Task 5 builds only `DownloadsTray` + `SavedSiteLauncher` (open in Safari) + a document-types/`onOpenURL` ingest; nothing else in the plan changes because everything downstream consumes `DownloadsTray.ingest(fileAt:…)`.
- [ ] **Step 5: Commit** only the findings note: `git add docs/superpowers/plans/2026-10-27-step10-spike-findings.md && git commit -m "Step 10 spike: WKWebView AutoFill and PDF capture findings"`. Delete `/tmp/mango-10-spike`.

### Task 2 [sonnet]: Document side panel and full-view modal

**Files:**
- Create: `Sources/MangoUI/Pad/Shared/DocumentPanel.swift`, `Sources/MangoUI/Pad/Shared/DocumentFullView.swift`, `Sources/MangoUI/Pad/Shared/DocumentPanelModel.swift`
- Modify: `Sources/MangoUI/Pad/Documents/PadDocumentPreview.swift` (reuse its PDF view), `Sources/MangoUI/Pad/Documents/PadDocumentsView.swift` and `PadMissingEvidenceView.swift` (adopt the panel), `Sources/MangoUI/Pad/PadRoutes.swift`, `scripts/render-phone-snapshots.sh` (ensure `--device ipad` can render 11" and 13", portrait and landscape; add `--ipad-size 11p|11l|13p|13l` or loop all four)
- Test: `Tests/MangoUITests/DocumentPanelModelTests.swift`

**Interfaces — Produces:**
- `struct DocumentPanelDetails: Equatable, Sendable { kind: String; from: String?; period: String?; amount: String?; date: String?; linkedTo: String? }` with `static func load(db: Database, documentId: Int64) throws -> DocumentPanelDetails` (a BudgetCore-free formatting wrapper over `EvidenceDocument`/`EvidenceLinkTitles`; fields absent are nil, never "—" strings).
- `struct DocumentPanel<Extra: View>: View { init(documentId: Int64, onClose: () -> Void, @ViewBuilder extra: () -> Extra) }`: ~380 pt wide, header with close, thumbnail, buttons "Open full view" (primary) and "Download/Share" (secondary, share sheet), details, then `extra`.
- `DocumentFullView(documentId:)`: modal, pages, pinch zoom, Share/Download, a "Show details" toggle.
- `DocumentPanelHost` view modifier `.documentPanel(selection: Binding<Int64?>)` placing the panel on the right in landscape and as a trailing overlay (same 380 pt, content shrinks behind) in portrait.

- [ ] **Step 1: Write failing tests:** `testDetailsOmitMissingFields`, `testAmountAndDateFormatted` (£/€ with sign rules of the existing formatters, no wrap-prone text), `testLinkedToNamesTheOwner` (uses `EvidenceLinkTitles`), `testPanelWidthIs380InLandscapeAndPortrait` (the pure layout function `DocumentPanelLayout.panelWidth(containerWidth:)` returns 380 and the content width stays ≥ 420).
- [ ] **Step 2: Run** `swift test --scratch-path $S10 --filter DocumentPanelModelTests` → FAIL.
- [ ] **Step 3: Implement** the three files and adopt the panel in Documents and Missing evidence (their existing detail panes become `DocumentPanel` with their old extras in `extra`). Routes `pad-document-panel`, `pad-document-fullview`.
- [ ] **Step 4: Verify.** Targeted tests; `scripts/build-phone.sh`; four-size snapshots of the two routes → 0 wrap violations; read the PNGs. Full suite.
- [ ] **Step 5: Commit** `git commit -m "iPad: one document panel and full-view modal, used by Documents and Missing evidence"`

### Task 3 [sonnet]: Collapsible sidebar, icon rail, footer, new section map

**Files:**
- Modify: `Sources/MangoUI/Pad/PadSection.swift`, `Sources/MangoUI/Pad/PadRootView.swift`, `Sources/MangoUI/Pad/PadRoutes.swift`
- Create: `Sources/MangoUI/Pad/Shared/PadSidebar.swift`, `Sources/MangoUI/Pad/Shared/SidebarFooter.swift`, `Sources/MangoUI/Pad/Shared/MangoGlyph.swift` (SwiftUI `Shape` drawing of the fruit; a simple path, not the app icon), `Sources/MangoUI/Pad/Shared/PlaceholderPadScreen.swift`
- Test: `Tests/MangoUITests/PadSectionTests.swift`

**Interfaces — Produces:**
- `PadSection` becomes: `home, month, accounts, search` (ungrouped) · Property: `thisMonth, billsAndRecharges, tenancies, money, calendar, checks, profile` · "Everything else": `evidence, documents`. Removed: `propertyOverview, bills, recharges, rentReceipts, missingEvidence` (their screens are re-homed by Tasks 11, 13, 14; until then the cases route to the old views through `PadSection.legacy`, deleted by the task that replaces each). `Missing evidence` is renamed **Evidence** (Task 14 builds it).
- `PadSection.groups(hasProperty:)` unchanged signature. `var requiresProperty: Bool`.
- `SidebarFooter(userName: String, avatar: Image?, sync: SyncSidebarStatus, onSettings: () -> Void)`: avatar + name only (no access level), sync line from `SyncSidebarStatus`/`SyncStatusCopy` ("Synced 2 min ago" / "N changes waiting"), Settings button (opens the existing `SettingsSheet`).
- `PadSidebarState { var isCollapsed: Bool }` stored with `@SceneStorage`; collapsed = ~72 pt icon rail with the glyph, section icons (each with accessibility label and `.help`), footer reduced to avatar, sync dot, gear.

- [ ] **Step 1: Write failing tests:** `testPropertyGroupOrderAndTitles` (exact titles: "This month", "Bills & recharges", "Tenancies", "Money", "Calendar", "Checks", "Profile"), `testEvidenceSitsUnderEverythingElseNotProperty`, `testNoPropertyHidesPropertyGroup`, `testEverySectionHasTitleAndSymbol`, `testFooterShowsNoAccessLevel` (the footer's text list contains the name and the sync line only), `testSyncLineCopy` (waiting / synced / never).
- [ ] **Step 2: Run** `--filter PadSectionTests` → FAIL.
- [ ] **Step 3: Implement.** Sections not yet built render `PlaceholderPadScreen(title)`. Collapse toggle in the sidebar header; also collapses automatically in portrait on 11" when a document panel is open *(my call)*.
- [ ] **Step 4: Verify.** Targeted + full suite, `scripts/build-phone.sh`, four-size snapshots `pad-sidebar-expanded`, `pad-sidebar-collapsed`.
- [ ] **Step 5: Commit** `git commit -m "iPad: collapsible sidebar with icon rail, footer and the new Property section map"`

### Task 4 [sonnet]: Button system and icon-button vocabulary

**Files:**
- Create: `Sources/MangoUI/Pad/Shared/PadButtons.swift`, `Sources/MangoUI/Pad/Shared/RowIconButton.swift`
- Modify: `Sources/MangoUI/Pad/Property/PadBillActions.swift`, `PadRechargesView.swift`, `PadRentReceiptsView.swift`, `PadTenanciesView.swift`, `Sources/MangoUI/Pad/Documents/PadDocumentActions.swift` (adopt the styles; no behaviour change)
- Test: `Tests/MangoUITests/PadButtonsTests.swift`

**Interfaces — Produces:**
- `enum PadButtonRole { case primary, secondary, textLink, destructive }` and `PadButtonSize { regular, small }`; `struct PadButtonStyle: ButtonStyle` (min tap target 44 pt; label `.lineLimit(1)`).
- `enum RowAction: CaseIterable { openSite, linkDocument, check, email, notExpected, download }` with fixed `systemImage` (`globe`, `paperclip`, `magnifyingglass`, `envelope`, `bell.slash`, `arrow.down.tray`) and `accessibilityLabel` ("Open site", "Link document", "Check", "Email", "Not expected any more", "Download").
- `RowIconButton(_ action: RowAction, perform: () -> Void)`: 44 pt target, label from the table, `.help`.

- [ ] **Step 1: Write failing tests:** `testIconVocabularyIsFixed` (the six pairs above exactly), `testEveryActionHasAnAccessibilityLabel`, `testNoTwoActionsShareASymbol`, `testMinimumTapTarget` (44).
- [ ] **Step 2: Run** `--filter PadButtonsTests` → FAIL. **Step 3: Implement** and swap the old in-row text buttons for `RowIconButton`s. **Step 4: Verify** (targeted, full, phone build, snapshots of `pad-bills`/`pad-recharges` → 0 wraps). **Step 5: Commit** `git commit -m "iPad: one button system and a fixed icon-button vocabulary"`

### Task 5 [opus]: Downloads tray and built-in browser (saved sites on device)

**Depends on Task 1's GO/NO-GO** (NO-GO: build the tray, `SavedSiteLauncher` and the `onOpenURL`/`.fileImporter` ingest instead of the WKWebView, per the findings note).

**Files:**
- Create: `Sources/BudgetCore/Phone/DownloadsTray.swift`, `Sources/BudgetCore/Phone/SavedSite.swift`, `Sources/MangoUI/Pad/Browser/BrowserModel.swift`, `Sources/MangoUI/Pad/Browser/BrowserView.swift` (WKWebView wrapper, `WKDownload` capture), `Sources/MangoUI/Pad/Browser/SavedSitesStrip.swift`, `Sources/MangoUI/Pad/Browser/TrayListView.swift`
- Modify: `Phone/Mango.entitlements` / `project.yml` only if Task 1 requires `webcredentials`; the sign-out/leave-household/demo paths in `Phone/Sync/PhoneSyncController.swift` (call `purge`); `Sources/MangoUI/Pad/PadRoutes.swift`
- Test: `Tests/BudgetCoreTests/DownloadsTrayTests.swift`, `Tests/BudgetCoreTests/SavedSiteTests.swift`, `Tests/MangoUITests/BrowserModelTests.swift`; fixtures `Tests/TestSupport/Fixtures/web/{form.html,bill.pdf,notpdf.pdf}`

**Interfaces — Produces:**
- `public struct TrayItem: Equatable, Identifiable, Sendable { id: UUID; fileName: String; sha256: String; byteCount: Int; receivedAt: Date; sourceHost: String? }`
- `public final class DownloadsTray: @unchecked Sendable` (serial queue): `init(directory: URL, now: @escaping @Sendable () -> Date = Date.init)`; `func ingest(fileAt url: URL, suggestedName: String, sourceHost: String?) throws -> TrayItem` (throws `TrayError.notAPDF` unless the first bytes are `%PDF-` and size > 0; same sha256 returns the existing item; moves the file in, sets `.completeUntilFirstUserAuthentication` and `isExcludedFromBackup`); `func items() -> [TrayItem]` (newest first); `func fileURL(for: TrayItem) -> URL`; `func discard(_ item: TrayItem)`; `func purgeAll()`. Item metadata is a JSON sidecar inside the same directory.
- `public struct SavedSite: Equatable, Identifiable, Sendable { id: UUID; name: String; url: URL; kind: SavedSiteKind; sortOrder: Int }`, `enum SavedSiteKind: String { bank, utility, tax, condominium, other }`; `SavedSite.validate(_ text: String) throws -> URL` (accepts only `https` with a host; adds `https://` to a bare host; throws `SavedSiteError.notHTTPS`/`.invalid`).
- `public protocol SavedSiteStore: Sendable { func all() async throws -> [SavedSite]; func save(_ site: SavedSite) async throws; func remove(id: UUID) async throws }` and `LocalSavedSiteStore` (UserDefaults suite, per device; starts empty, "+ Add site" adds).
- `BrowserModel`: `@Observable`; `load(_ site: SavedSite)`, `isLoading`, `currentHost`, `downloadedItems: [TrayItem]` (emits after capture), `func purgeAll() async` (tray + `WKWebsiteDataStore.default().removeData(...)`). `BrowserView` shows the strip, a minimal address bar (read-only host), back/forward, and a "Downloads (n)" button opening `TrayListView` (rows: file name middle-truncated, host, time, `RowIconButton(.check)` which Task 8 wires, discard).

- [ ] **Step 1: Write failing tests:** `testNonPDFRefused` (HTML named `.pdf` → `.notAPDF`), `testEmptyFileRefused`, `testSameHashKeptOnce`, `testIngestSetsProtectionAndBackupExclusion` (read attributes back; protection attribute asserted where the filesystem reports it), `testItemsNewestFirst`, `testDiscardAndPurgeAllDeleteFiles`, `testOnlyHTTPSAccepted` (`javascript:`, `file:`, `http://`, empty → throw; `example.com/login` → `https://example.com/login`), `testBareHostGetsHTTPS`, `testLocalStoreRoundTripAndOrder`, `testSignOutPurgesTrayAndWebsiteData` (fake `WebsiteDataClearing` protocol injected into `BrowserModel`; tray empty; clear called once), `testBrowserNeverLoadsNonHTTPSSite`, `testDownloadOfPDFLandsInTray` (drives `BrowserModel.handleCapturedDownload(at:suggestedName:host:)` with the fixture PDF; the real `WKDownload` path is exercised by Task 1's spike and the iPad snapshot only, never against a real site).
- [ ] **Step 2: Run** the three filters → FAIL.
- [ ] **Step 3: Implement.** Copy the capture code from the findings note. No credentials, no cookie export, no JS injected. A `Close site` action clears nothing (the person stays signed in until sign-out *(my call)*), but sign-out, leaving the household and demo all call `BrowserModel.purgeAll()`. Demo mode: the browser is hidden.
- [ ] **Step 4: Verify.** Targeted, full suite, `scripts/build-phone.sh`, `scripts/build-core-ios.sh`, snapshots `pad-browser`, `pad-tray` at four sizes (fixture data) → 0 wraps.
- [ ] **Step 5: Commit** `git commit -m "iPad: built-in browser with saved sites and an app-private Downloads tray"`

### Task 6 [opus]: Saved sites as household data (the one new CloudKit record type)

**Why a new type is needed:** no synced table has a URL column (`utilityProvider` has none, and BBVA, Portal das Finanças and the condomínio are not providers). Record type = table name (`SyncSchema`), so a household-synced list is a new table `savedSite` → a new CloudKit record type → **a Production schema deploy is required before TestFlight/App Store builds sync it** (list the type and fields for the user's deploy step). `SyncSchema.version` 8 → 9. If the user prefers no schema change, drop this task: sites stay device-local.

**Files:**
- Modify: `Sources/BudgetCore/Database/` (the next migration: `savedSite(id, name, url, kind, sortOrder)`; follow the latest migration's registration style), `Sources/BudgetCore/Sync/SyncSchema.swift` (table entry, `version = 9`, unique key `savedSite(url)` → `.identity`), `SyncTables.swift`/triggers as `SyncChangeTracker` requires, `Sources/BudgetCore/Phone/SavedSite.swift` (add `GRDBSavedSiteStore: SavedSiteStore` writing through `DeviceWriter`), `Sources/BudgetCore/Access/AccessAreaMap.swift` (area: `.property`)
- Test: `Tests/BudgetCoreTests/SavedSiteSyncTests.swift`, plus the existing `SyncSchemaTests` / `SyncChangeTrackerTests` hash pins updated for version 9

**Interfaces — Produces:** `GRDBSavedSiteStore(writer: DeviceWriter, reader: any DatabaseReader)`: `all()` sorted by `sortOrder`; `save`/`remove` write as `.property` (Edit required). `SavedSiteSeed.defaults(db:) -> [SavedSite]`: suggests one site per `utilityProvider` is *not* done (no URLs known); the strip starts empty and "+ Add site" is the only source. URLs go through `SavedSite.validate` on save **and on load** (a synced bad URL from another device is skipped, never loaded).

- [ ] **Step 1: Write failing tests:** `testSavedSiteSyncsBetweenAdminAndMember` (TwoPersonHousehold + FakeCloud; member with Property Edit adds, admin pulls), `testViewOnlyMemberCannotAddOrRemove` (AccessDenied, nothing queued), `testBadURLFromSyncIsSkipped`, `testSavedSiteIsHouseholdNotPrivate` (visible at household level, no account linkage), `testSchemaVersionIs9AndEveryColumnClassified` (existing `SyncSchemaTests` passes), `testMigrationAddsTableToExistingDatabase`, `testNoCredentialFieldExists` (the table's columns are exactly the five above).
- [ ] **Step 2: Run** `--filter 'SavedSiteSyncTests|SyncSchemaTests|SyncChangeTrackerTests'` → FAIL. **Step 3: Implement**; the browser's `SavedSiteStore` is swapped to `GRDBSavedSiteStore` when a household database is present, `LocalSavedSiteStore` otherwise (demo). **Step 4: Verify** targeted, full suite, `scripts/check-actor-writes.sh`, `scripts/build-core-ios.sh`, Mac build (shared schema). **Step 5: Commit** `git commit -m "Sync: saved sites as household data (schema v9, new savedSite record type)"`

### Task 7 [opus]: Check-and-link engine in BudgetCore

**Files:**
- Create: `Sources/BudgetCore/Property/CheckAndLink.swift`, `Sources/BudgetCore/Property/CheckAndLinkCopy.swift`
- Modify (only to expose existing Mac logic, no behaviour change): `UtilityInvoiceIntake.swift`, `Import/ImportCoordinator.swift`/`DocumentImport/ImportPipeline.swift` entry points if not `public`
- Test: `Tests/BudgetCoreTests/CheckAndLinkTests.swift`; fixtures: synthetic utility-invoice PDFs and a BBVA statement PDF already used by the reader tests

**Interfaces — Consumes:** `TrayItem`/`DownloadsTray` (Task 5), `DocumentClassifier`, `UtilityInvoiceIntake.propose(document:library:propertyId:ocr:)` / `.paymentCandidates` / `.bestPayment` / `.record` / `.attach`, `BBVAStatementReader` + `StatementChecks`/`StatementCheck`, `ImportPipeline`/`ImportApplier` (statement import), `EvidenceLinkGuard`, `DeviceWriter.writeCheckingFiledYears`. *(Verify the exact Mac signatures when starting; this task reuses them, it must not fork the rules.)*

**Interfaces — Produces:**
- `public enum CheckAndLinkProposal: Equatable, Sendable { case utilityBill(UtilityBillFields), statement(StatementImportSummary), document(DocumentFields) }`, each with `FieldOrigin` per field (`.read`/`.typed`, so the UI marks "read").
- `UtilityBillFields`: kind, provider (`UtilityProvider.id?`), property, period, amount, issue date, invoice number, `paidBy: PaymentSuggestion?` (suggested, changeable; from `bestPayment`), `tenantShare`, `joinsStatement: RechargeStatement.ID?`.
- `public enum CheckAndLink { static func propose(db: Database, item: TrayItem, fileURL: URL, propertyId: Int64) throws -> CheckAndLinkProposal; static func save(_ decision: CheckAndLinkDecision, item: TrayItem, tray: DownloadsTray, library: EvidenceLibrary, writer: DeviceWriter) async throws -> CheckAndLinkResult }`.
- `save` stores the file in the library (becomes a normal `document` and syncs), applies the same link/attach/record steps as the Mac, through `writer.writeCheckingFiledYears`, then `tray.discard(item)`. A `.statement` proposal saves through the statement import path with its checks (balance, account, duplicates) exactly as the Mac. On refusal (`filedYear`, `AccessDenied`, `EvidenceLinkGuard.Failure`) nothing is stored and **the tray item stays**.

- [ ] **Step 1: Write failing tests:** `testUtilityInvoiceProposalMatchesMacIntake` (same fields as `UtilityInvoiceIntake.propose` for the fixture), `testFieldsReadFromPDFAreMarkedRead`, `testPaidBySuggestedAndChangeable`, `testTenantShareAndStatementJoin`, `testBBVAStatementRoutesToStatementImport` (fixture BBVA PDF → `.statement` with the Mac's check results), `testStatementMismatchBlocksSaveWithReason`, `testDuplicateOfExistingDocumentSaysSo`, `testUnknownDocumentFallsBackToDocumentKindPicker`, `testSaveWritesNothingUntilCalled` (propose leaves row counts unchanged), `testSaveStoresDocumentLinksAndDiscardsTrayItem`, `testSaveInFiledYearRefusedTrayItemKept` (2022/23 period → `DeviceWriteRefusal.filedYear`, row counts and pending sync unchanged, item still in the tray), `testMemberWithoutPropertyEditDenied`, `testSaveIsOneTransaction` (a failure after the document insert leaves no partial rows).
- [ ] **Step 2: Run** `--filter CheckAndLinkTests` → FAIL. **Step 3: Implement.** **Step 4: Verify:** targeted, full, `scripts/check-actor-writes.sh`, `scripts/build-core-ios.sh`, Mac build. **Step 5: Commit** `git commit -m "Check-and-link: tray files proposed and saved with the Mac's import checks"`

### Task 8 [sonnet]: Check-and-link sheet

**Files:**
- Create: `Sources/MangoUI/Pad/Browser/CheckAndLinkSheet.swift`, `Sources/MangoUI/Pad/Browser/CheckAndLinkModel.swift`
- Modify: `Sources/MangoUI/Pad/Browser/TrayListView.swift` (`RowIconButton(.check)` opens it), `Sources/MangoUI/Pad/PadRoutes.swift`
- Test: `Tests/MangoUITests/CheckAndLinkModelTests.swift`

**Interfaces — Consumes:** `CheckAndLink.propose/save` (Task 7), `DocumentPanel` (Task 2), `PadRefusalBanner`. **Produces:** `CheckAndLinkModel` (`@Observable`): `proposal`, `edits`, `canSave`, `refusal: String?`, `save()`.

- [ ] **Step 1: Write failing tests:** `testSaveDisabledUntilRequiredFieldsPresent`, `testReadFieldsShowReadBadge`, `testSaveShowsFiledYearRefusalInlineAndKeepsSheetOpen`, `testStatementProposalShowsChecksAndBlocksOnMismatch`, `testCheckHiddenWithoutPropertyEdit`, `testCancelChangesNothing`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** the sheet: left the PDF (thumbnail + Open full view), right fields (kind, provider, property, period, amount, dates; "read" badges), "Paid by" row with Change, utility-bill block (tenant's share, the statement it joins), primary Save and text-link Cancel only. **Step 4: Verify** targeted, full, phone build, snapshots `pad-check-utility`, `pad-check-statement`, `pad-check-refusal` at four sizes. **Step 5: Commit** `git commit -m "iPad: check-and-link sheet for downloaded files"`

### Task 9 [opus]: This-month checklist (computed)

**Files:**
- Create: `Sources/BudgetCore/Property/ThisMonthChecklist.swift`, `Sources/BudgetCore/Property/ThisMonthCopy.swift`
- Test: `Tests/BudgetCoreTests/ThisMonthChecklistTests.swift`

**Interfaces — Consumes:** `Recharges`, `UtilityBills` (grid and stages), `RentReceiptPayments`, `PropertyGlance`, `PropertyCalendar`, `MissingEvidence`/`PropertyEvidence` counts, `DownloadsTray.items().count` (passed in as `trayCount`). **Produces:**
- `public struct ThisMonthChecklist: Equatable, Sendable { tenancyId: Int64; month: Date; steps: [Step]; side: [SideItem]; evidenceCount: Int; downloadsWaiting: Int }`; `Step { id: StepID(.lastRechargePaid, .billsIn, .chargesInGrid, .emailTenant); state: StepState(.done, .needsYou, .waiting, .notApplicable); headline: String; detail: String?; actions: [ChecklistAction] }`; `ChecklistAction { .fetchStatement(siteKind), .confirmMatch(transactionId), .openSite(providerId), .check(trayItemId), .prepareEmail(statementId), .markReceived }`; `SideItem` (rent receipt, condomínio).
- `ThisMonthChecklist.build(db: Database, tenancyId: Int64, today: Date, trayCount: Int) throws -> ThisMonthChecklist`. Nothing is stored; no new table.
- Rules: (1) last month's recharge: `done` when a tenant transfer matches exactly; `needsYou` with the candidate when not exact (confirm); `waiting` when none seen yet; `notApplicable` for a tenancy's first month. (2) per provider: fetched / checked / missing from the bills grid stage; providers not expected this month are skipped. (3) `done` automatically when every expected bill is checked (stage ≥ invoice in). (4) email: `needsYou` when a draft statement exists unsent, `done` when sent, `waiting` before step 3.

- [ ] **Step 1: Write failing tests:** `testNewTenancyFirstMonthStepOneNotApplicable`, `testExactTransferMarksStepOneDone`, `testTwoTransfersSummingToRechargeCountAsPaid`, `testInexactTransferNeedsConfirmation`, `testNoTransferYetWaiting`, `testPerProviderStatesFromGrid`, `testNothingExpectedStepTwoNotApplicable`, `testStepThreeFollowsStepTwo`, `testEmailStepFollowsStatementState`, `testSentStatementIsDone`, `testSideItemsAndCounts`, `testBuildWritesNothing`, `testSelectedTenancyOnly`, `testMemberWithoutExpenseVisibilityHidden` (levels as `AccessPolicy`), `testNoTenantPersonalNameInCopy` (copy uses the tenancy's name).
- [ ] **Step 2: Run** `--filter ThisMonthChecklistTests` → FAIL. **Step 3: Implement.** **Step 4: Verify** targeted, full, `scripts/build-core-ios.sh`. **Step 5: Commit** `git commit -m "Property: this-month checklist computed from the existing read models"`

### Task 10 [sonnet]: This month screen

**Files:**
- Create: `Sources/MangoUI/Pad/Property/PadThisMonthView.swift`, `PadThisMonthModel.swift`
- Modify: `Sources/MangoUI/Pad/PadRootView.swift` (Property landing = This month), `PadRoutes.swift`
- Test: `Tests/MangoUITests/PadThisMonthModelTests.swift`

**Interfaces — Consumes:** `ThisMonthChecklist` (Task 9), `BrowserView`/`SavedSite` (Tasks 5–6), `CheckAndLinkSheet` (Task 8), `RowIconButton`. Produces the screen only.

- [ ] **Step 1: Write failing tests:** `testActionsRouteToBrowserCheckAndEmail` (action → `PadDestination`), `testConfirmMatchWritesThroughDeviceWriterWithFiledYearRefusal`, `testEditActionsHiddenWithoutPropertyEdit`, `testTenancyPickerChangesChecklist`, `testSideColumnShowsDownloadsWaiting`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement:** tenancy selector, four-step checklist (state badge, headline, icon actions), side column. "Confirm match" uses `RentReceiptPayments.link` via the writer. **Step 4: Verify** targeted, full, phone build, snapshots `pad-this-month`, `pad-this-month-empty`, `pad-this-month-allDone` at four sizes. **Step 5: Commit** `git commit -m "iPad: This month checklist screen"`

### Task 11 [sonnet]: Bills & recharges (merged screen)

**Files:**
- Create: `Sources/MangoUI/Pad/Property/PadBillsAndRechargesView.swift`, `PadBillsGridView.swift`, `PadStatementsList.swift`, `PadBillsAndRechargesModel.swift`
- Modify: `PadSection`/`PadRootView` (replace `legacy` cases), delete `PadBillsView.swift`, `PadRechargesView.swift`, `PadRechargesModel.swift`, `PadBillActions.swift` only after their actions are moved
- Test: `Tests/MangoUITests/PadBillsAndRechargesModelTests.swift`

**Interfaces — Consumes:** `UtilityBills` (grid/stages), `Recharges`, `RechargeEmail.lineDetails/overview`, `DocumentPanel`. **Produces:** grid cells coloured by stage with the stage names exactly: expected · invoice in · linked to payment · in a statement · sent · paid by tenant; statements list below with "Prepare email" on the draft (wired by Task 12). Every Mac action reachable: record/correct an invoice total, attach, link payment, not-expected, charges, payment suggestions (secondary actions in the panel's `extra` or a More menu).

- [ ] **Step 1: Write failing tests:** `testGridStageNamesAndOrder`, `testTappingABillSelectsItsDocumentForThePanel`, `testPanelExtraShowsPaidByAndStatement`, `testEditsHiddenWithoutPropertyEdit`, `testFiledYearEditRefusedInline`, `testCorrectInvoiceTotalThroughWriter`, `testEveryMacBillAndRechargeActionIsListed` (a table of the Mac tab's action names vs the iPad's `PadBillsAction.allCases`; fails when one is missing).
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Verify** targeted, full, phone build, `scripts/check-actor-writes.sh`, snapshots `pad-bills-recharges`, `pad-bills-panel` at four sizes. **Step 5: Commit** `git commit -m "iPad: Bills & recharges as one screen with the document panel"`

### Task 12 [opus]: Prepare email (statement email with PDFs; the person sends)

**Files:**
- Create: `Sources/BudgetCore/Property/RechargeEmailPackage.swift`, `Sources/MangoUI/Pad/Property/PrepareEmailSheet.swift`, `Sources/MangoUI/Pad/Shared/MailComposer.swift` (`MFMailComposeViewController` wrapper + `UIActivityViewController` fallback)
- Test: `Tests/BudgetCoreTests/RechargeEmailPackageTests.swift`, `Tests/MangoUITests/PrepareEmailSheetTests.swift`

**Interfaces — Consumes:** `RechargeEmail.draft(db:statementId:language:…)`, `RechargeEmail.lineDetails`, the Mac's statement PDF/sheet builder and its mark-sent function (find them in `App/Property/RechargeSheets.swift` / `RechargePanels.swift`; move any Mac-only builder code into BudgetCore unchanged so both call it). **Produces:**
- `public struct RechargeEmailPackage: Equatable, Sendable { subject: String; body: String; to: [String]; attachments: [Attachment(fileName, url)]; missing: [String] }` and `RechargeEmailPackage.build(db:, statementId:, language:, library:) throws -> RechargeEmailPackage` (statement sheet PDF + the bills' PDFs; `missing` names absent files/recipient).
- `markSent(statementId:, writer: DeviceWriter) async throws` (same state change as the Mac; filed-year/permission checks through the writer).
- `MailComposer.present(package:, onFinished: (Outcome) -> Void)` with `Outcome { sent, saved, cancelled, failed }`; falls back to the share sheet when `MFMailComposeViewController.canSendMail()` is false.

- [ ] **Step 1: Write failing tests:** `testPackageMatchesMacDraftSubjectAndBody`, `testAttachmentsAreStatementPlusBillPDFs`, `testMissingPDFAndNoRecipientListedNotThrown`, `testTenantNameOnlyInEmailText`, `testBuildWritesNothing`, `testMarkSentOnlyAfterConfirmedOutcome` (model: `.cancelled` and `.failed` leave the statement unsent; `.sent` asks the person to confirm "Mark as sent", never automatic), `testNoMailFallsBackToShareSheet`, `testMarkSentRefusedForViewOnlyMember`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement**; the sheet previews subject/body/attachments (read-only), buttons "Open in Mail" (primary), "Share instead" (secondary). **Step 4: Verify** targeted, full, phone build, Mac build (builder moved), `scripts/check-actor-writes.sh`. **Step 5: Commit** `git commit -m "iPad: prepare the tenant's recharge email with the PDFs; the person sends"`

### Task 13 [sonnet]: Tenancies

**Files:**
- Create: `Sources/MangoUI/Pad/Property/PadTenanciesScreen.swift`, `PadTenancyDetailView.swift`, `PadRentReceiptRow.swift`
- Modify: delete `PadTenanciesView.swift`, `PadRentReceiptsView.swift` once re-homed; `PadSection`/`PadRootView`
- Test: `Tests/MangoUITests/PadTenanciesModelTests.swift`

**Interfaces — Consumes:** `Properties`/tenancy models, `RentReceiptPayments`, `RentReceiptPDFs`, `RentReceiptsExport`, `RentReceiptImport`, `DocumentPanel`, `BrowserView` (Portal das Finanças site). **Produces:** tenancy list/details (the tenant's personal name appears here), rent receipts by month, selected receipt in the panel with the single line "Rent paid: tenant transfer of €X on <date> · BBVA · Change" (Change opens the candidate credits from `RentReceiptPayments.candidateCredits`), "Fetch from Portal das Finanças" opens the browser on the saved tax site (or offers "+ Add site" when none). Export/import and other Mac actions in a More menu.

- [ ] **Step 1: Write failing tests:** `testRentPaidLineCopy` (exact format, amount via the shared formatter), `testChangeShowsCandidateCredits`, `testNoPaidLineWhenUnmatchedShowsLinkAction`, `testTenantNameOnlyOnThisScreen` (other Pad models' titles contain the tenancy name, asserted via a helper over all Pad view-model titles), `testEditsHiddenWithoutPropertyEdit`, `testFiledYearRefusalInline`, `testEveryMacTenancyActionIsListed`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement. Step 4: Verify** targeted, full, phone build, snapshots `pad-tenancies`, `pad-tenancies-panel` at four sizes. **Step 5: Commit** `git commit -m "iPad: Tenancies with rent receipts in the document panel"`

### Task 14 [opus]: Evidence for the tax year

**Files:**
- Create: `Sources/BudgetCore/Evidence/TaxYearEvidence.swift`, `Sources/MangoUI/Pad/Documents/PadEvidenceView.swift`, `PadEvidenceModel.swift`
- Modify: `PadSection`/`PadRootView` (Evidence under Everything else), delete `PadMissingEvidenceView.swift` after re-homing
- Test: `Tests/BudgetCoreTests/TaxYearEvidenceTests.swift`, `Tests/MangoUITests/PadEvidenceModelTests.swift`

**Interfaces — Consumes:** `MissingEvidence`, `MissingEvidenceDetail`, `EvidenceRequirement` (its "source" text), `EvidenceLinkGuard`, `TransactionDocuments`, `SavedSite`. **Produces:**
- `public struct EvidenceArea: Equatable, Sendable { area: EvidenceAreaKind(.employmentIncome, .ukTax, .pensionGifts, .lisbonFlat); items: [EvidenceItem] }`; `EvidenceItem { requirement, why: String, state(.have/.missing), suggestedSiteKind: SavedSiteKind?, canLink: Bool }`.
- `TaxYearEvidence.areas(db:, taxYear:, viewerCanSee: …) -> [EvidenceArea]`: **utility bills are excluded** (not evidence); Lisbon flat holds rent receipts, IMI, condomínio, insurance, repairs.
- Actions: **Open site** (browser, matching saved site kind) and **Link existing document** (picker of library documents; saves through the writer with `EvidenceLinkGuard`). Tax-year switch at top; the current year default.

- [ ] **Step 1: Write failing tests:** `testGroupedByAreaInOrder`, `testUtilityBillsNeverAppear`, `testSwitchingTaxYearChangesItems`, `testEachItemHasWhy`, `testOnlyViewerVisibleAreasShown` (private/hidden tax areas of the other person excluded), `testLinkExistingDocumentThroughWriter`, `testLinkInFiledYearRefusedInline` (EvidenceLinkGuard failure shown, nothing saved), `testOpenSiteUsesMatchingSavedSiteKindOrOffersAdd`, `testEditsHiddenWithoutDocumentsEdit`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement. Step 4: Verify** targeted, full, `scripts/check-actor-writes.sh`, `scripts/build-core-ios.sh`, phone build, snapshots `pad-evidence`, `pad-evidence-panel` at four sizes. **Step 5: Commit** `git commit -m "iPad: evidence for the tax year, grouped by area, utility bills excluded"`

### Task 15 [sonnet]: Money and Calendar

**Files:**
- Create: `Sources/MangoUI/Pad/Property/PadMoneyView.swift`, `PadMoneyModel.swift`, `PadCalendarView.swift`, `PadCalendarModel.swift`; `Sources/BudgetCore/Property/PropertyCalendarGrid.swift`
- Test: `Tests/BudgetCoreTests/PropertyCalendarGridTests.swift`, `Tests/MangoUITests/PadMoneyModelTests.swift`, `PadCalendarModelTests.swift`

**Interfaces — Consumes:** `PropertyFinance`, `PropertyMonthBreakdown`, `PropertyMoneySelection`, `TransactionDocuments`, `PropertyCalendar` (obligations), `DocumentPanel`. **Produces:**
- Money: month list → selecting a transaction opens the document panel (its documents; empty state offers Link document); charges and the full figures table reachable (More menu / "All figures").
- `PropertyCalendarGrid.month(_ month: Date, items: [PropertyCalendar.Item], calendar: Calendar) -> [GridDay]` (6×7 weeks, leading/trailing days flagged, items per day). Calendar screen: agenda of the next 12 months plus a small month grid; tapping a day filters the agenda.

- [ ] **Step 1: Write failing tests:** `testGridHasWholeWeeksStartingOnLocaleFirstWeekday`, `testItemsLandOnTheirDay`, `testAgendaCoversNext12Months`, `testLeapDayAndYearBoundary`, `testMoneyMonthListOrdersNewestFirst`, `testTransactionSelectionOpensPanelWithDocuments`, `testFiguresTableAmountsMatchPropertyFinance`, `testEveryMacMoneyAndCalendarCapabilityListed`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement. Step 4: Verify** targeted, full, `scripts/build-core-ios.sh`, phone build, snapshots `pad-money`, `pad-calendar` at four sizes. **Step 5: Commit** `git commit -m "iPad: Money and Calendar (agenda plus month grid)"`

### Task 16 [opus]: Checks and Profile (incl. mortgage terms editing)

**Files:**
- Create: `Sources/MangoUI/Pad/Property/PadChecksView.swift`, `PadChecksModel.swift`, `PadProfileView.swift`, `PadProfileModel.swift`, `PadMortgageTermsSheet.swift`; `Sources/BudgetCore/Property/MortgageTermsEditing.swift` (validation shared with `App/Property/MortgageTermsSheet.swift`)
- Test: `Tests/BudgetCoreTests/MortgageTermsEditingTests.swift`, `Tests/MangoUITests/PadChecksModelTests.swift`, `PadProfileModelTests.swift`

**Interfaces — Consumes:** `PropertyChecks`, `PropertyCheckDecision`, `PropertyRecurringSeries`, `PropertySetUp`, `PropertyMortgageTerms`, `MortgageProjection`, `InterestIndex`, `DeviceWriter`. **Produces:**
- Checks: per recurring cost a "Not expected any more" icon button (`RowAction.notExpected`) with an Undo toast; no separate list of not-expected items.
- Profile: property details, utility providers, email templates, mortgage terms editing via `PadMortgageTermsSheet` (Save/Cancel; fields and validation exactly the Mac's), through `writeCheckingFiledYears`.
- `MortgageTermsEditing.validate(_ terms: PropertyMortgageTerms) -> [Problem]` (moved from the Mac sheet, both call it); `save(terms:, writer:) async throws`.

- [ ] **Step 1: Write failing tests:** `testNotExpectedThenUndoRestoresTheCost`, `testNotExpectedHiddenWithoutPropertyEdit`, `testNotExpectedInFiledYearRefusedInline`, `testMortgageValidationMatchesMac` (same cases as the Mac's existing sheet tests), `testMortgageSaveThroughWriter`, `testMortgageEditChangingFiledYearFigureRefusedNothingSaved`, `testCancelLeavesTermsUntouched`, `testMemberViewOnlySeesTermsReadOnly` (no Edit control present), `testEveryMacChecksAndProfileActionListed`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement. Step 4: Verify** targeted, full, `scripts/check-actor-writes.sh`, `scripts/build-core-ios.sh`, Mac build, phone build, snapshots `pad-checks`, `pad-profile`, `pad-mortgage-terms` at four sizes. **Step 5: Commit** `git commit -m "iPad: Checks and Profile with mortgage terms editing"`

---

## Controller-only (after the last task, not subagents)

- Whole-branch review. Run `scripts/check-actor-writes.sh`, `scripts/build-core-ios.sh`, the Mac build and the phone build; one full 4-size iPad snapshot pass of every `pad-*` route (0 wrap violations). Merge to `main`, `xcodegen` in the main checkout, then `scripts/install-app.sh` (Mac shared-code changes).
- **CloudKit Production schema:** Task 6 adds record type `savedSite` (fields `name`, `url`, `kind`, `sortOrder` plus the sync metadata fields every type has). **Deploy the Development schema to Production before the TestFlight build syncs it.** No other schema change.
- **What the user does:** (1) deploy the schema in the CloudKit Dashboard; (2) one real-device check of Passwords AutoFill in the browser (Face ID prompt, a real provider login), the only thing the simulator cannot prove; (3) add the saved sites (BBVA, each provider, Portal das Finanças, condomínio); (4) TestFlight upload (bump `CURRENT_PROJECT_VERSION`, `scripts/archive-phone.sh`, upload needs the user's go).
