# iPhone & iPad design review and design system

Status: 2026-10-28, proposal for the user to review. Written from the rendered demo routes
(`scripts/render-phone-snapshots.sh`, iPhone 393×852 and iPad 1194×834 light/dark, .large and .xxxLarge) and the
code in `Sources/MangoUI`. Mockups: the "Mango iPhone & iPad redesign" design canvas (21 boards: design system,
7 iPhone screens, 8 iPad screens, 3 journeys). Figures and names in the mockups are invented.

Goal (user): "very easy to use and beautiful". Pablo glances and makes quick edits on iPhone; Patricia runs the
Lisbon flat's month and the tax year's evidence on iPad.

## 1. Summary

The building blocks are good: one theme object (`PhoneTheme`), one font entry point (`mangoFont`), one iPad page
scaffold (`padPage`, `PadSpacing`, `PadMetrics`), one side panel (`PadSidePanel`), one button system (`PadButtonStyle`),
row icon buttons (`RowIconButton`) and a wrap probe that keeps figures on one line. The problems are above that level:

- **Too many places for the same thing.** Three upcoming lists, two net-worth cards, four places to find a missing
  document, two ways to open the browser, salary in two different spots.
- **The iPad sidebar has 14 items and doesn't fit.** At 1194×834 *Documents* is below the fold of the sidebar, and
  *Evidence* is half cut (`pad-root`, every iPad route).
- **iPhone screens are stretched onto the iPad.** Home, Month and Search on iPad are the iPhone views at 880 pt wide:
  one column of full-width cards with a 300 pt chart (`pad-root`, `pad-search-query`).
- **Colour carries little meaning.** Every spending category is a red disc (`month`), unknown ones an orange "?"
  (`search`), sidebar selection is system blue, page actions are blue text links. Red is the most common colour on
  screens that are mostly fine.
- **The system is applied unevenly.** iPad pages mix filled primary buttons, outlined secondary buttons and blue text
  links for the same weight of action; pickers are drawn three ways; selection is drawn two ways.

## 2. Findings

Route names are the demo routes in `DemoRoutes.swift` / `PadRoutes.swift`.

### 2.1 Inconsistencies

| # | Where (route) | What | Fix |
|---|---|---|---|
| I1 | `transaction-detail` vs `quick-edit-sheet` | Detail footer says "Edit on iPad or Mac" (`SearchViewModel.detailFooter`) though the iPhone has Quick edit for category and note. Two sheets for one transaction. | One transaction sheet with an Edit button that turns into a Cancel/Save form in place. |
| I2 | `month`, `search`, `search-results` | Category icons: white glyph on a red disc for all spending, orange "?" for uncategorised. Red reads as "problem". | Neutral disc (`surface-2`, glyph `text-secondary`); colour only for status (over plan, uncategorised badge). |
| I3 | `quick-sort` | Category chips: white text on mid-grey fill, about 2.5:1. Fails 4.5:1. | Chips on `surface` with `text`; chosen chip `accent-tint`. |
| I4 | `pad-this-month`, `pad-bills-recharges`, `pad-tenancies`, `pad-money` | Tenancy picker drawn three ways: black title + chevrons (Bills), blue link (Tenancies), "Tenancy 2 · October 2026" title (This month). Year picker right-aligned on Bills, left on Money. | One `ContextPicker` (accent-tint capsule) in the header's context line, always left, always first. |
| I5 | iPad pages | Page actions: "New tenancy" filled + "More" outlined (Tenancies); "Match tenant credits" / "Prepare October 2026" blue text links (Bills); "Prepare statement" outlined, "See the grid" and "Open Evidence" text (This month); "Edit" small outlined buttons per card (Profile). | One primary per page in the header; step actions secondary; text buttons only inside running text; card edits as icon buttons. |
| I6 | `pad-documents` vs `pad-accounts` | Selected row: solid blue fill with white text (Documents) vs light tint (Accounts, sidebar). | Selected row = `accent-tint` fill + 3 pt accent leading bar everywhere. |
| I7 | `pad-accounts` | Account action "Fetch statem…" is truncated in the panel. Labels must not truncate. | Icon buttons in the panel header (tray-arrow = import, pencil = edit). |
| I8 | `pad-tenancies` | Rent receipt rows use an eye icon (not in the agreed vocabulary) next to paperclip and globe. | Remove the eye; tapping the row opens the panel. |
| I9 | `pad-evidence` | Sidebar says "Evidence", the page title says "Missing documents". | One name: Documents ▸ Missing (see D3). |
| I10 | `pad-calendar` | Two segmented controls side by side (Month/Agenda and Upcoming/Past). | One control for the view; past is reached by scrolling back. Add a Personal/Flat filter instead. |
| I11 | `salary` (iPhone) | Denser type than every other screen (footnote rows, 13 pt inputs), "Current/New" segmented although the iPad shows both columns. | Same form row as Settings; two columns on iPhone too (they fit at 92 pt each). |
| I12 | `pad-sidebar-expanded` | Money and Salary share the same `sterlingsign.circle` symbol; Evidence uses `exclamationmark.magnifyingglass`. | Distinct symbols per destination (see the canvas sidebar). |
| I13 | Widgets (`widgets-preview`, `Widgets/*.swift`) | Widgets use `.font(.system(size: 9…14))` and `minimumScaleFactor(0.5)`: the chosen font doesn't apply and figures shrink instead of staying whole. | Widgets read the font id from the app group and use `mangoFont`; shorten copy rather than scale. |
| I14 | `CategoryRow`, `TransactionRow`, `LockScreen`, `PadProfileView` | Raw `.font(.system(size:))` (51 call sites in MangoUI/Phone/Widgets, most for glyphs) and `.red` hard-coded in Profile's map pin and two sheets. | Glyphs may keep system sizing, but text must go through `mangoFont`; colours through theme tokens. Add a lint. |
| I15 | `prepare-email` | Two "done" actions: a check mark in the nav bar and "Mark as sent…" at the bottom, plus "Open in Mail" and "Share instead". | Primary "Send in Mail" (marks sent on return); "Share instead" secondary; no nav-bar check. |
| I16 | Settings (`settings`) | "Lock now" is the first row; sync status and "Sync now" sit under About; Salary is under "Tools". | Avatar sheet "Me": person + sync first, then Salary, Appearance, Font, Sharing, Widgets & notifications, Lock. |

### 2.2 Duplicated features and where to consolidate

| # | Duplicates | Consolidate into |
|---|---|---|
| D1 | Home ▸ Upcoming (iPhone/iPad), Property ▸ Coming up (iPhone `property`), iPad Calendar agenda (`pad-calendar`) | **Calendar** owns obligations (personal and flat). Home shows the next 4 from it with a "Calendar" link; the iPhone Flat tab shows the next 2 flat items. One `UpcomingList` component. |
| D2 | Net worth card on Home and on Accounts (same figure, same chart) | Home keeps the card (tile on iPad). Accounts gets a one-line header: "Net worth £128,077.28 · +£7,960 since Dec". |
| D3 | Evidence page, Checks' missing items ("show evidence"), This month's "Evidence for the tax year" card, Documents ▸ Waiting | **Documents** with three segments: *Missing* (step 20's centre, filters for tax year / area), *Library*, *Downloads*. This month links to Missing with its count. |
| D4 | "Sites & downloads" header button, "Downloads waiting" card and its "Sites & downloads" link (This month), globe buttons in rows | Globe icon in rows opens that site; one globe icon in the This month header opens the browser; Downloads live in Documents ▸ Downloads and in This month's right column. |
| D5 | Money, Checks and Profile as three Property pages (`pad-money`, `pad-checks`, `pad-profile`) | **Flat details** with segments *Money · Costs · Profile*. "Not expected any more" on recurring costs lives in Costs. |
| D6 | Salary calculator: iPhone Settings ▸ Tools; iPad sidebar "UK Salary Calculator" | Same name "Salary calculator" on both; iPhone behind the avatar (Me sheet), iPad in "Everything else". |
| D7 | Two transaction sheets on iPhone (detail, then edit on top) | One sheet (I1). |
| D8 | Bills & recharges summary: four tiles (Outstanding, Recharged, Bills paid, Difference) where two always mirror each other | Three figures in one strip: Waiting for the tenant · Recharged this year · Matches bank (Yes / €x off). |

### 2.3 Wasted space

- **iPad Home** (`pad-root`): one 880 pt column; net-worth chart ~300 pt tall; at 834 pt high only two cards are
  visible. Proposal: 3-column tile grid (Left to spend spans 2, Net worth, Flat month, Needs you, Missing documents,
  Upcoming in two columns). Everything fits above the fold.
- **iPad Search** (`pad-search-query`): one result per 100 pt row across 880 pt; day header and the row repeat the
  amount. Proposal: results list at ~500 pt with the transaction in the side panel.
- **iPad Month**: iPhone `MonthView` stretched. Proposal: categories in two columns, transactions in the panel.
- **iPad Salary** (`salary` on iPad): labels at the far left, values 600 pt away. Proposal: inputs and results side by side.
- **iPad This month** (`pad-this-month`): the progress line is a 2 pt hairline and "0 of 4 done" a separate line;
  each step card is 260 pt tall at .large with a lot of padding. Proposal: 4-segment progress bar with the count
  inline; completed steps collapse to one line; the current step is expanded and outlined.
- **iPad Bills** (`pad-bills-recharges`): legend takes two lines above the grid; month navigation as text links.
  Proposal: stage names inside each cell ("Paid", "Sent"…) so no legend is needed; chevron icon buttons.
- **iPhone Accounts** (`accounts`): every row repeats "Imported · through <date>" (2 lines under each name).
  Proposal: show freshness only when stale (amber pill with the date).
- **iPhone Home** (`home`): five full-width cards, about 2.5 screens long; "Net worth" leads although Pablo opens the
  phone to check the month. Proposal: "Left to spend" first, then 2 tiles, Needs you, Upcoming (about 1.1 screens).

### 2.4 Other issues found while reviewing

- `pad-checks` crashes the snapshot run (the iPad run produces no PNGs when it's included; every other iPad route
  renders on its own). It needs a look before Checks moves into Flat details.
- A full iPad run (all routes, four sizes) didn't finish; batches of 3 routes did.

## 3. Design system

Everything here maps onto existing code: tokens become `PhoneTheme` roles (filled per `ThemePalette`), type goes
through `mangoFont`, spacing is `PadSpacing` (shared with the iPhone), components replace per-screen views.

### 3.1 Colour (semantic roles; Mango theme shown, every theme fills the same roles)

| Role | Light | Dark | Use |
|---|---|---|---|
| bg | #F4F2EE | #121110 | screen background |
| surface | #FFFFFF | #1E1C1A | cards, panels, rows |
| surface-2 | #F8F6F2 | #282522 | tiles inside cards, category discs, thumbnails |
| separator | #E6E2DA | #3A3632 | hairlines |
| text | #1B1A17 | #F3F0EA | primary text, figures |
| text-secondary | #5E5A52 (6.6:1) | #B9B3A9 | detail lines, labels |
| text-tertiary | #736E66 (4.9:1) | #9C968C | placeholders, disabled hints |
| accent | #B4530A (5.0:1) | #FFA45C | primary buttons, selection bar, links |
| accent-tint | #FCE9D6 (text #8A4006) | #3A2614 (text #FFC58F) | selected rows, pickers, "to do" |
| income | #1D7A3A | #5BD48A | money in |
| expense | #B3261E | #FF8A80 | money out, over plan |
| transfer | #2F5BC8 | #8EAEFF | transfers |
| pending | #8A5A00 | #F2C14E | estimates, waiting, close to plan |
| done / waiting / problem tints | #E5F2E8 / #FBF0D4 / #FBE3E1 | #16301E / #33290F / #3A1715 | status pills, banners |

Rules: all text roles ≥ 4.5:1 on `surface` (PhoneTheme already darkens income/expense; extend that to accent and
pending). Status is never colour alone: pills always carry a word. Proposed: a new "Mango" theme as the default for
new installs (warm neutral + mango accent); Classic stays.

### 3.2 Type (on `mangoFont`, Dynamic Type, all 13 faces)

| Style | Size/leading, weight | Use |
|---|---|---|
| largeTitle | 34/41 bold | page title |
| figureXL | 34 bold, tabular | hero figure (Left to spend, account balance) |
| title2 | 22/28 bold | sheet and panel titles on iPhone |
| title3 | 20/25 semibold | section headers (`PadSectionHeader`) |
| figureL | 22 semibold, tabular | tile figures |
| headline | 17/22 semibold | card titles, row titles that matter |
| body | 17/22 | rows, inputs |
| subheadline | 15/20 | row detail |
| footnote | 13/18 | captions, freshness |
| caption | 12/16 semibold | group labels (uppercase), pills; the floor |

Figures: a `.figure` modifier on `mangoFont` = tabular digits + `lineLimit(1)` + no scale factor + layout priority
(the wrap probe stays the safety net). Names: `lineLimit(1)` + `.truncationMode(.middle)`. No `.font(.system…)` for
text anywhere, widgets included.

### 3.3 Spacing, radii, elevation

- Spacing: 4 · 8 · 12 · 16 · 24 · 32 (`PadSpacing`, moved to the shared design system and used by the iPhone).
  iPhone gutter 16, iPad page inset 32 (20 compact), card padding 16, between tiles 12, between sections 24.
- Radii: 8 chips/pills, 12 controls (buttons, inputs, pickers), 16 cards and tiles, 24 sheets; capsules for search.
- Elevation: e0 cards flat on `bg` (no shadow); e1 side panel and floating tab bar (0 8 24 / 8%); e2 menus and
  toasts (0 12 40 / 18%). Dark mode uses lighter surfaces, not shadows.

### 3.4 Components

- **Page header**: large title; one context line (context picker + secondary text); trailing: up to two icon
  buttons and at most one primary button. iPhone and iPad share it (`PadPageHeader` generalised).
- **Context picker**: accent-tint capsule, label + chevron; tenancy, month, tax year. Always the first thing in the
  context line.
- **Card / Tile**: `Card` (title optional, 16 padding, radius 16). `Tile` = label (footnote, secondary) · figureL ·
  caption; the whole tile is a button to its home screen; tiles in a row share height (`PadGrid`).
- **List row**: min 56 pt; leading neutral glyph disc (32 pt) optional; title (truncates middle) over detail;
  trailing status pill, figure (never truncates), up to two icon buttons. Tapping the row opens the panel (iPad) or
  pushes (iPhone). Selected: accent-tint + 3 pt accent bar.
- **Icon buttons** (row actions, 44 pt): globe = open site, paperclip = link document, magnifier = check,
  envelope = email, bell-slash = not expected, tray-arrow = download/import, pencil = edit, ellipsis = more.
  Each has an accessibility label. No eye icon.
- **Buttons**: primary (accent fill, white), secondary (surface, accent text, hairline), text (inside sentences only),
  destructive (problem tint). 44 pt min; labels never truncate (shorten the copy).
- **Status pill**: done / waiting / problem / to do / neutral; always a word.
- **Side panel** (iPad): `PadSidePanel` as is (320–720, default 400, remembered), plus a visible grip; header with
  title, subtitle, ≤ 3 icon buttons, close; footer with Cancel/Save when it edits. Opening another row replaces the
  content. iPhone equivalent: push, or one sheet at medium/large detent.
- **Form row**: label left, value right; values read from a PDF carry a "read" pill; edits save only on Save;
  Cancel/Save in the same place every time (sheet nav bar on iPhone, panel footer on iPad).
- **Step card** (This month): number disc (done = green tick, now = accent, later = outline), title, one status
  line, expanded body only for the current step, one action.
- **Charts**: accent line, dashed forecast, a dot for today, two gridlines, footnote labels; bars in money colours;
  ≤ 4 series; heights capped (iPad 180 pt, iPhone 120 pt) so a chart never pushes content below the fold.
- **Empty / loading / error**: empty says what is fine and the next action ("Nothing missing for 2025/26");
  loading keeps the layout with skeleton blocks; errors and refusals inline where the action was (`PadRefusalBanner`).
- **Navigation**: iPhone tab bar Home · Month · Accounts · Flat (when she/he sees the property) + the system search
  tab; avatar button top-right on Home opens "Me" (tools and settings). iPad sidebar of 11 in three groups, badges for
  work waiting (This month, Documents), collapsible rail, footer = avatar, name, sync, Settings.

## 4. Information architecture

| Job | iPhone | iPad | Removed / merged |
|---|---|---|---|
| Glance at the month and money | Home (Left to spend, tiles, Needs you, Upcoming) | Home (3-column tiles) | Home ▸ Net worth as lead card |
| Spending by category | Month | Month (2 columns + panel) | — |
| Balances and an account | Accounts → account (push) | Accounts (list + panel) | Accounts net-worth card |
| Find a transaction | Search tab | Search (list + panel) | — |
| Flat's monthly routine | Flat tab: checklist progress, next step, next 2 flat items (read-mostly) | This month (checklist) | iPhone Property tab's mortgage block → Flat details |
| Bills, statements, email | — (status only) | Bills & recharges | — |
| Tenancy, receipts (tenant's name lives here) | — | Tenancies | — |
| Flat money, recurring costs, profile, mortgage | — | Flat details: Money · Costs · Profile | Money, Checks, Profile pages |
| Missing documents (tax + flat), library, downloads | Count on Home | Documents: Missing · Library · Downloads | Evidence page, This month evidence card, Checks evidence link |
| Fetch from a website | — | Globe on rows; browser sheet with saved sites | Separate "Sites & downloads" buttons |
| Everything due | Upcoming on Home → Calendar | Calendar (All · Personal · Flat) | Property ▸ Coming up |
| Salary what-if | Me ▸ Salary calculator | Salary calculator | Settings ▸ Tools |
| Settings | Me sheet | Sidebar footer gear | — |

iPad sidebar (11): Home, Month, Accounts, Search · **Flat**: This month, Bills & recharges, Tenancies, Flat details ·
**Everything else**: Documents, Calendar, Salary calculator. Fits 834 pt with room for badges.

## 5. Implementation plan (prioritised)

Each step keeps logic in BudgetCore, renders with the snapshot script, and checks the wrap report.

1. **Quick fixes** (S): Quick sort chip contrast (I3); remove the eye icon (I8); "Fetch statement" → icon buttons in
   the Accounts panel (I7); Calendar single segmented control (I10); Prepare email single completion (I15); rename
   "UK Salary Calculator" → "Salary calculator" and give Money/Salary distinct symbols (I12).
2. **Tokens and type** (M): add the roles to `PhoneTheme` (surface-2, separator, text tiers, accent-tint, status tints)
   with contrast tests per theme; add `.figure` to `mangoFont`; move `PadSpacing`/radii to the shared design system;
   neutral category discs (I2); widgets on `mangoFont` without scale factors (I13); lint for `.font(.system` on Text
   and hard-coded `.red` (I14). Optional: a "Mango" theme.
3. **Shared components** (M): `PageHeader` + `ContextPicker` for iPhone and iPad (I4, I5); `ListRow` with selection
   state (I6); `Tile`; `StatusPill`; `StepCard`; `UpcomingList` (D1).
4. **iPad sidebar and IA** (L): 14 → 11 items; Flat details with Money · Costs · Profile segments (D5, fix the
   `pad-checks` render crash first); Documents with Missing · Library · Downloads (D3, builds on step 20); downloads
   and sites consolidation (D4); Calendar moves to Everything else with personal items.
5. **iPad layouts** (M): Home tile grid; Month two columns + panel; Search list + panel; Salary side by side;
   This month progress bar and collapsing steps; Bills summary strip and labelled cells (D8).
6. **iPhone** (M): Home reorder (Left to spend first, tiles); one transaction sheet with in-place edit (I1, D7);
   Accounts compact header and stale-only freshness (D2); Me sheet (I16, D6); Flat tab as checklist progress;
   two-column salary form (I11).
7. **Journeys polish** (S): Patricia's recharge flow end to end on iPad at all four sizes; Pablo's quick check on
   iPhone; evidence flow — each as a snapshot route sequence.

## 6. Canvas

Pages: Design system (Main, Tokens, Components), iPhone (Home, Month, Accounts + transaction sheet, Search, Salary,
Me/Settings, Widgets), iPad (Home, This month, Bills & recharges + panel, Tenancies, Documents + panel, Accounts +
panel, Calendar, Salary), Journeys (Patricia's monthly recharge, Pablo's quick check, tax-year evidence).
