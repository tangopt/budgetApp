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
| accent | #B2520A (5.1:1) | #FFA45C | primary buttons, selection bar, links |
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
- **Step card / list row rule: pill or action, never both.** A row shows either a status pill (when nothing is needed
  from the user: Done, Waiting for tenant, Not due yet) or a single button naming the action (when the user must act:
  "Check & link", "Prepare statement", "Send email"). The secondary line says the state in words ("2 invoices
  downloaded, not checked yet"). Only the current step's action is the filled prominent button; later actionable
  steps use the plain secondary style.
- **Salary form: bonus and pension always offer £/%.** Every Bonus and Pension field (Current and New) shows a £/%
  segmented toggle beside the input, always visible, not only once a value is entered. When % is selected the
  computed amount appears as a secondary line ("= £5,200").
- **Charts**: accent line, dashed forecast, a dot for today, two gridlines, footnote labels; bars in money colours;
  ≤ 4 series; heights capped (iPad 180 pt, iPhone 120 pt) so a chart never pushes content below the fold.
- **Empty / loading / error**: empty says what is fine and the next action ("Nothing missing for 2025/26");
  loading keeps the layout with skeleton blocks; errors and refusals inline where the action was (`PadRefusalBanner`).
- **Navigation**: iPhone tab bar Home · Month · Accounts · Flat (when she/he sees the property) + the system search
  tab; avatar button top-right on Home opens "Me" (tools and settings). iPad sidebar of 11 in three groups, badges for
  work waiting (This month, Documents), collapsible rail, footer = avatar, name, sync, Settings.

### 3.5 Themes (seven theme sets)

A **theme set** replaces today's two separate pickers (15 colour themes in `PhoneTheme`/`ThemePalette`, 13 faces in `FontCatalog`). One choice sets the colour palette (light and dark, filling every role in 3.1) and the font pairing together. Seven sets, no more. System / Light / Dark stays a separate Appearance control; every set has both a light and a dark palette.

| Set | Intent | Display (headings) | Body | Figures (tabular) | Accent light / dark |
|---|---|---|---|---|---|
| **Mango** (default) | Warm: mango-orange accent on cream, deep warm dark. Default for new installs. | SF Pro Rounded | SF Pro | SF Pro (tabular) | #B2520A / #FFA45C |
| **Classic** | Today's iOS look: system blue on grouped greys. | SF Pro | SF Pro | SF Pro (tabular) | #0A5FD0 / #4DA3FF |
| **Editorial** | Paper and ink with a deep red accent; serif headings. | New York | SF Pro | SF Pro (tabular) | #8E1B22 / #F0837C |
| **Clear** | Maximum legibility: highest contrast, blue-black accent, visible borders. | Atkinson Hyperlegible | Atkinson Hyperlegible | Atkinson Hyperlegible (tabular digits are in the file) | #0A2472 / #9DBBFF |
| **Studio** | Graphite, dark-first, lime accent in dark and teal in light; mono figures. | IBM Plex Sans | IBM Plex Sans | IBM Plex Mono | #00695C / #C6F24E |
| **Calm** | Sage green on soft greys; round humanist type. | Manrope | Source Sans 3 | SF Pro (tabular) | #3A6849 / #8CC4A0 |
| **Library** | Parchment ground, bottle-green accent in light, deep brown-black with a soft green accent in dark; one serif for everything. | Source Serif 4 | Source Serif 4 | Source Serif 4 (tnum, lnum) | #1F4D36 / #8FC7A0 |

Font roles map onto `mangoFont`: **display** = largeTitle, title2, title3, headline and the sidebar brand; **body** = body, subheadline, footnote, caption, buttons, pills; **figure** = everything with the `.figure` modifier (figureXL, figureL, table cells, pills carrying amounts). `PhoneFont` stays as the file/registration catalogue but the 13-face picker, its Settings section and the per-user font key go; only the faces used here are registered (SF Pro, SF Pro Rounded and New York are system; Atkinson Hyperlegible, IBM Plex Sans, IBM Plex Mono, Manrope, Source Sans 3 and Source Serif 4 are already bundled; Inter, Public Sans, DM Sans and Lexend can be dropped from the bundle and the licences list). All seven figure faces have tabular digits (`hasTabularDigits` is true for each), so no system fallback is needed; if a future face lacks them the figure role falls back to SF Pro tabular.

**Mango**

| Role | Light | Dark |
|---|---|---|
| bg | #F4F2EE | #121110 |
| surface | #FFFFFF | #1E1C1A |
| surface-2 | #F8F6F2 | #282522 |
| separator | #E6E2DA | #3A3632 |
| text | #1B1A17 (17.4:1) | #F3F0EA (14.9:1) |
| text-secondary | #5E5A52 (6.9:1) | #B9B3A9 (8.2:1) |
| text-tertiary | #736E66 (5.1:1) | #9C968C (5.8:1) |
| accent | #B2520A (5.1:1) | #FFA45C (8.7:1) |
| on-accent (button label) | #FFFFFF | #121110 |
| accent-tint | #FCE9D6 | #3A2614 |
| accent-tint text | #8A4006 | #FFC58F |
| income | #1D7A3A | #5BD48A |
| expense | #B3261E | #FF8A80 |
| transfer | #2F5BC8 | #8EAEFF |
| pending | #8A5A00 | #F2C14E |
| done / waiting / problem pills (text on tint) | #1D7A3A on #E4EFE7 / #8A5A00 on #F1EBE0 / #B3261E on #F6E5E4 | #5BD48A on #293D2E / #F2C14E on #443A23 / #FF8A80 on #47302C |

**Classic**

| Role | Light | Dark |
|---|---|---|
| bg | #F2F2F7 | #000000 |
| surface | #FFFFFF | #1C1C1E |
| surface-2 | #EDEDF2 | #2C2C2E |
| separator | #D1D1D6 | #38383A |
| text | #000000 (21.0:1) | #FFFFFF (17.0:1) |
| text-secondary | #58585D (7.1:1) | #AEAEB2 (7.7:1) |
| text-tertiary | #6B6B6F (5.3:1) | #939397 (5.6:1) |
| accent | #0A5FD0 (5.9:1) | #4DA3FF (6.5:1) |
| on-accent (button label) | #FFFFFF | #000000 |
| accent-tint | #DCE9FC | #10294D |
| accent-tint text | #0A4AA0 | #A9CFFF |
| income | #207A35 | #4CD97B |
| expense | #AB1F15 | #FF6B63 |
| transfer | #6B3FC0 | #B49BFF |
| pending | #8F5600 | #FFC947 |
| done / waiting / problem pills (text on tint) | #207A35 on #E4EFE7 / #8F5600 on #F2EBE0 / #AB1F15 on #F5E4E3 | #4CD97B on #253E2F / #FFC947 on #453B25 / #FF6B63 on #452A2A |

**Editorial**

| Role | Light | Dark |
|---|---|---|
| bg | #F6F1E7 | #15120F |
| surface | #FFFDF8 | #1F1B17 |
| surface-2 | #F0EADD | #2A251F |
| separator | #DDD4C2 | #3D362D |
| text | #1A1714 (17.6:1) | #F1EBDF (14.4:1) |
| text-secondary | #57514A (7.7:1) | #BDB4A5 (8.3:1) |
| text-tertiary | #6B645A (5.7:1) | #9A9283 (5.6:1) |
| accent | #8E1B22 (8.9:1) | #F0837C (6.7:1) |
| on-accent (button label) | #FFFFFF | #15120F |
| accent-tint | #F6DEDC | #3B1B1A |
| accent-tint text | #721218 | #FFB4AE |
| income | #247840 | #6FD493 |
| expense | #B03618 | #FF9A6B |
| transfer | #2F4F9A | #9DB6F2 |
| pending | #85540A | #E9BC55 |
| done / waiting / problem pills (text on tint) | #247840 on #E5EFE8 / #85540A on #F0EAE2 / #B03618 on #F6E7E3 | #6FD493 on #2D3C2D / #E9BC55 on #433822 / #FF9A6B on #473226 |

**Clear**

| Role | Light | Dark |
|---|---|---|
| bg | #F3F5F8 | #05070D |
| surface | #FFFFFF | #0F141F |
| surface-2 | #E8ECF2 | #1A2130 |
| separator | #737E92 | #7C879B |
| text | #0B1020 (18.9:1) | #FFFFFF (18.4:1) |
| text-secondary | #2F3747 (11.9:1) | #D5DBE6 (13.2:1) |
| text-tertiary | #4B5565 (7.5:1) | #AEB8C8 (9.2:1) |
| accent | #0A2472 (13.9:1) | #9DBBFF (9.6:1) |
| on-accent (button label) | #FFFFFF | #05070D |
| accent-tint | #D9E3FA | #1B2B58 |
| accent-tint text | #0A2472 | #D2E0FF |
| income | #12742F | #6BE59A |
| expense | #98001B | #FF8080 |
| transfer | #5B2E9E | #C9ADFF |
| pending | #7A4A00 | #FFD166 |
| done / waiting / problem pills (text on tint) | #12742F on #E3EEE6 / #7A4A00 on #EFE9E0 / #98001B on #F3E0E4 | #6BE59A on #203A35 / #FFD166 on #3A362C / #FF8080 on #3A2730 |

**Studio**

| Role | Light | Dark |
|---|---|---|
| bg | #EDF0F1 | #0E1012 |
| surface | #FFFFFF | #171A1D |
| surface-2 | #E3E8EA | #20252A |
| separator | #CBD2D6 | #323941 |
| text | #14181B (17.9:1) | #ECEFF1 (15.1:1) |
| text-secondary | #4A545B (7.7:1) | #B0B8BF (8.7:1) |
| text-tertiary | #5D6971 (5.6:1) | #8C959D (5.7:1) |
| accent | #00695C (6.6:1) | #C6F24E (13.5:1) |
| on-accent (button label) | #FFFFFF | #0E1012 |
| accent-tint | #D3EEE8 | #1F2C10 |
| accent-tint text | #00473E | #D9F78F |
| income | #1B773C | #5FE0A8 |
| expense | #A8231A | #FF8579 |
| transfer | #3556B8 | #8FB0FF |
| pending | #855300 | #FFC857 |
| done / waiting / problem pills (text on tint) | #1B773C on #E4EFE8 / #855300 on #F0EAE0 / #A8231A on #F5E5E4 | #5FE0A8 on #243E36 / #FFC857 on #413927 / #FF8579 on #412D2E |

**Calm**

| Role | Light | Dark |
|---|---|---|
| bg | #F1F4F0 | #141815 |
| surface | #FBFCFA | #1D221E |
| surface-2 | #E7ECE5 | #272E29 |
| separator | #D6DDD3 | #38413A |
| text | #232A25 (14.3:1) | #E8EDE8 (13.6:1) |
| text-secondary | #505B54 (6.9:1) | #B4BEB6 (8.4:1) |
| text-tertiary | #606C66 (5.3:1) | #929D94 (5.7:1) |
| accent | #3A6849 (6.3:1) | #8CC4A0 (8.1:1) |
| on-accent (button label) | #FFFFFF | #141815 |
| accent-tint | #DDEBDF | #243428 |
| accent-tint text | #2A4A37 | #B5E0C3 |
| income | #25793F | #72D894 |
| expense | #A32B21 | #F59388 |
| transfer | #42609C | #9AB4E8 |
| pending | #80560A | #E8BF63 |
| done / waiting / problem pills (text on tint) | #25793F on #E5EFE8 / #80560A on #F0EBE2 / #A32B21 on #F4E6E4 | #72D894 on #2C4333 / #E8BF63 on #423E2A / #F59388 on #443631 |

**Library**

| Role | Light | Dark |
|---|---|---|
| bg | #F3EBDA | #1A1510 |
| surface | #FBF6EA | #231D17 |
| surface-2 | #EBE2CE | #2E261E |
| separator | #D6CAB0 | #433A2E |
| text | #231C14 (15.6:1) | #EFE6D2 (13.4:1) |
| text-secondary | #4F4538 (8.7:1) | #BFB39C (8.1:1) |
| text-tertiary | #62574A (6.5:1) | #A09580 (5.6:1) |
| accent | #1F4D36 (9.0:1) | #8FC7A0 (8.6:1) |
| on-accent (button label) | #FFFFFF | #1A1510 |
| accent-tint | #DCE8DA | #25382B |
| accent-tint text | #173B29 | #BFE3C9 |
| income | #2C7140 | #86D69A |
| expense | #A8321E | #FF9A82 |
| transfer | #3A5A94 | #9DB4E8 |
| pending | #85540A | #E5BC5C |
| done / waiting / problem pills (text on tint) | #2C7140 on #E6EEE8 / #85540A on #F0EAE2 / #A8321E on #F5E6E4 | #86D69A on #353E2F / #E5BC5C on #463A23 / #FF9A82 on #4B342A |

Library notes: ratios are on `surface` (on `bg` the accent is 8.2:1 light and 9.4:1 dark; on `surface-2` 7.5:1 and 7.7:1). Lowest text pair: text-tertiary 5.0:1 on dark `surface-2`, 5.5:1 on light `surface-2`; lowest status colour: income 4.6:1 on light `surface-2`. On-accent label 9.7:1 light, 9.4:1 dark; accent-tint text 9.8:1 / 9.0:1. The dark accent (#8FC7A0) and dark income (#86D69A) are close in hue, so income is never shown by colour alone (sign or word), as in the other sets; in light the accent (luminance 0.06) is far darker than income (0.13). Font pairing: Source Serif 4 (bundled since step 16, variable optical size 8..60, weights 400 and 600) for display, body and figures; figures turn on `tnum` and `lnum` (`font-feature-settings`, in SwiftUI `.monospacedDigit()` plus the lining-figures feature) so digits are tabular and lining; Source Serif 4's tabular digit is about 0.55 em, narrower than Plex Mono's 0.6 em, so Studio stays the layout worst case.


Tints for the status pills are derived, not hand-picked: tint = the status colour mixed 12% (light) or 18% (dark) into the surface, and the pill text is the status colour nudged toward black/white until it reaches 4.5:1 on that tint. The roles `done`/`waiting`/`problem`/`sent` come from income/pending/expense/transfer.

**Contrast rules and checks (all seven sets, light and dark; computed, not eyeballed):**

- text, text-secondary, text-tertiary reach 4.5:1 on `bg`, `surface` and `surface-2`. Lowest: text-tertiary 4.5:1 (Mango light, the 3.1 value kept), text-secondary 5.9:1 (Calm light), text 11.7:1. Calm's and Studio's tertiaries were nudged to clear `surface-2`, not just `surface`.
- accent used as text or link is >= 4.5:1 on all three grounds (lowest 4.6:1, Mango light). **Refinement to 3.1:** Mango's light accent moves from #B4530A to #B2520A, because #B4530A is 4.49:1 on `bg`. On-accent button labels are >= 5.1:1 in every set.
- income, expense, transfer and pending are >= 4.5:1 on `bg`, `surface` and `surface-2` in both modes (lowest 4.5:1: Calm light income). Accent-tint text is >= 6.3:1 on accent-tint; status pill text is >= 4.5:1 on its tint.
- **Status never relies on hue alone.** Pills always carry a word and an icon (check, clock, exclamation, arrow); money carries a sign or a word. Lightness helps where contrast allows: in dark, expense is the darkest of income/expense/pending (relative luminance 0.33 to 0.45 against 0.51 to 0.68), so a red amount reads as a different grey from green and amber. In light, the 4.5:1 floor keeps all three between 0.07 and 0.14 luminance (expense darkest in Classic, Clear, Studio, Calm; Mango and Editorial are closer), so there the glyph, word and sign carry the meaning. A grayscale snapshot of Home and Bills & recharges in every set is part of acceptance.
- Editorial keeps accent (#8E1B22) darker than expense (#B03618) so a red button never reads as an expense amount. Studio's lime accent (dark) and income green (#5FE0A8) are distinct in lightness (0.76 vs 0.59 relative luminance) and income always carries a sign.
- Clear uses visible borders instead of tint steps: separator #737E92 light (3.7:1 on `bg`) and #7C879B dark (>= 3:1 on surfaces), 1 pt on every control and card.

**Layout across all seven sets.** The widest face is IBM Plex Mono for figures (digit advance 0.6 em; SF tabular is about 0.6 em as well, Atkinson and Manrope narrower), so Studio is the worst case and drives the rules:

- Figure columns size from the data, not a constant: min width = `chars x 0.6 x size + 2 x padding`. Bills grid cell at 14 pt: `€48.91` = 6 chars = 50 pt + 16 pt padding = 66 pt, cell with the side panel open is about 84 pt, so it fits; a four-digit amount (`€1,234.56`, 76 pt + 16) does not, so the Bills grid shows 3 month columns instead of 4 when the widest figure in view needs more (ViewThatFits on column count, not shrinking text).
- Hero figures (`figureXL` 34 pt) in Plex Mono: `£12,345.67` = 10 chars = 204 pt, fits the 358 pt phone tile and the 3-up iPad tile (about 250 pt inner).
- Headings in New York, Manrope and Atkinson are up to 6% wider than SF: sidebar labels (248 pt column, 190 pt text area), page titles (one line at 34 pt up to 22 characters) and picker chips were checked; none needs a different layout. The wrap probe runs per set.
- Rounded and serif display faces change only weight/width of headings; line heights come from the text style, not the face, so row heights (56 pt) and touch targets (44 pt) are unchanged.
- Result: the one layout rule above (Bills grid columns follow the widest figure) is the only adjustment; it applies to Studio with large amounts and is harmless in the others.

**Settings.** One section, "Theme", under the Appearance control (System / Light / Dark). It shows seven preview cards (2 columns on iPhone with Library full-width on the last row, 4 x 2 on iPad with the eighth cell left empty): each card is rendered in its own palette and fonts, in the current appearance, with the name set in its display face, a figure in its figure face, an accent button chip and the font names in a 12 pt line; the selected card has a 2 pt accent ring and a check. The font section, "All 13 fonts" list and swatch row are removed. Cards are radio buttons (VoiceOver: "Editorial, serif headings, selected"), 88 pt tall, so touch targets are met. Widgets read the set from the shared app-group key.

**Migration (one time at first launch of the new build; old keys are left in place so a rollback works).** Map by colour theme; the chosen font only decides when the colour theme is Classic (the neutral set):

| Old colour theme | New set | Why |
|---|---|---|
| Classic | Classic | same look |
| Ocean | Classic | blue accent, cool greys |
| Ledger | Library | cream paper in light and warm brown-black in dark, the same ground family as the old Ledger palette (#FBF6E8 / #1F1B15), and the serif suits an accounts book; Editorial's ground is similar but its red accent and sans body fit Ledger less |
| Sunset, Solarized, Sakura, Desert | Mango | warm grounds and warm accents |
| Forest, Nord, Lavender, Mint | Calm | soft, cool or muted accents on quiet greys |
| Dracula, Graphite, Midnight | Studio | dark graphite grounds; if the old theme was dark-only, Appearance is set to Dark once |
| High Contrast | Clear | contrast is the point |

Font tie-break when the colour theme was Classic: New York -> Editorial; Source Serif 4 -> Library; IBM Plex Sans or Plex Mono -> Studio; Atkinson Hyperlegible or Lexend -> Clear; Manrope, Source Sans 3 or Public Sans -> Calm; SF Pro Rounded -> Mango; SF Pro, Inter, DM Sans -> Classic. A fresh install gets Mango. The user keeps their System/Light/Dark choice.

**Tests.** (1) Contrast test per set and mode over every pair above (extends the step 2 token test; 7 x 2 palettes). (2) Snapshot matrix: Home, Bills & recharges, Month and Settings on iPhone and iPad in all seven sets, three in dark. (3) Wrap probe in all seven sets at default and one larger Dynamic Type size. (4) Migration test: 15 colour themes x 13 fonts maps to exactly one set each. (5) Grayscale snapshot for status legibility.

The canvas boards `Themes` (seven sets side by side) and `Themes - Screens` (iPad Bills & recharges in all seven, three in dark) show the result; `iPhone - Settings` shows the picker.

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
   and hard-coded `.red` (I14). The Mango theme arrives with the theme sets (step 8).
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
8. **Theme sets** (L): replace the 15 colour themes and the 13-font picker with the seven sets in 3.5 (`ThemeSet` = light and dark
   `ThemeTokens` + a display/body/figure font pairing, resolved by `mangoFont`); one "Theme" picker with preview cards
   in Settings (iPhone and iPad) next to the unchanged System/Light/Dark control; one-time migration from the old
   colour theme and font keys; drop unused bundled faces and licences; contrast test over 7 x 2 palettes, snapshot
   matrix in all sets, wrap probe per set, Bills grid columns sized from the widest figure. Large because it touches
   every screen's look, widgets and the persisted settings; do it after step 2 (roles) and 3 (components) so it is
   one palette swap, not a rewrite.

## 6. Canvas

Pages: Design system (Main, Tokens, Components, Themes, Themes - Screens), iPhone (Home, Month, Accounts + transaction sheet, Search, Salary,
Me/Settings with the Theme picker, Widgets), iPad (Home, This month, Bills & recharges + panel, Tenancies, Documents + panel, Accounts +
panel, Calendar, Salary), Journeys (Patricia's monthly recharge, Pablo's quick check, tax-year evidence).
