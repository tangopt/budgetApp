# Companion apps — overview, name, distribution and build order

Status: for the user's review (2026-10-22). This is the index of the companion-app specs:

| Spec | Covers |
|---|---|
| `2026-10-21-authentication-design.md` (from the desktop session) | Identity, Mac sign-in, lock, recovery, attribution. The source of truth. |
| `2026-10-22-sync-and-access-design.md` | CloudKit sync, sharing levels and permissions, security, migration, changes requested to the auth spec |
| `2026-10-22-iphone-app-design.md` | iPhone screens, widgets, notifications |
| `2026-10-22-ipad-app-design.md` | iPad screens: import, categorise, recharges |

Mockups (private to the user): https://claude.ai/artifact/4bdRGqbyqKA1vQPwBLCYhZ. Its pages are
Feature × device, iPhone (9 screens), iPad (6) and Mac sign-in (2).

## 1. Feature × device

Full = everything the Mac does. **Light** = view plus the listed small edits. View = read-only.
— = not there.

| Feature | Mac | iPad | iPhone |
|---|---|---|---|
| **Identity & security** | | | |
| Lock (Touch ID / Face ID) | Full | Full | Full |
| Household members, invite | Full (admin) | View | Accept invite |
| Two people on the Mac | One macOS user each, with real privacy | — | — |
| Sharing level of my accounts | Full | Full | View |
| Member permissions per area | Full (admin) | Full (admin) | View |
| Security check (ADP, FileVault) | Full | Full | Full |
| **Overview** | | | |
| Dashboard | Full | Full | Glance |
| Accounts & net worth | Full | Light: update a manual balance | Light: update a manual balance |
| Add / edit accounts, bank details | Full (each person on their own macOS user) | Full (your own accounts) | — |
| Net worth & year-on-year charts | Full | View | View |
| This pay month vs budget | Full grid | Month + read-only grid | Month view |
| Plan amounts, planned items | Full | — | — |
| Search transactions | Full | Full | Full |
| Edit a transaction | Full | Full | Light: category, note, receipt photo |
| Split, manual entry, transfer links | Full | Full | — |
| Upcoming bills & obligations | Full | View | View |
| **Workflow** | | | |
| Import documents | Full | Full (Files, Mail, camera, drag & drop) | Share to Inbox |
| Bank statements (BBVA, UK CSV/PDF) | Full | Full | — |
| New bank layout (mapping) | Full | Waits for the Mac | — |
| Import history & Undo | Full | Full | — |
| Uncategorized | Full | Full (multi-select, drag) | Quick sort |
| Rules & learnt import rules | Full | View (corrections still teach) | — |
| Categories & groups | Full | — | — |
| **Property** | | | |
| Property at a glance | Full | Full | Glance |
| Tenancies & rent receipts | Full | View + attach receipt PDF | View |
| Monthly utility recharges | Full | Full | Status + accept split |
| Mortgage, rate, loan charts | Full | View | Glance |
| Calendar & checks | Full | View | Upcoming only |
| Property set-up, owners, terms | Full | — | — |
| **Forecast & tax** | | | |
| Forecast & scenario lab | Full | — | — |
| Forecast figures on dashboards | Full | View | View |
| Tax years, SA computation, exports | Full | — | — |
| Tax deadlines & payments due | Full | View | View |
| **Documents** | | | |
| Documents library | Full | Full (Pencil markup on a copy) | Preview |
| Missing evidence checklist | Full | Full + camera | — |
| **System** | | | |
| Widgets | Later | Full | Full |
| Notifications | Optional | Full | Full |
| Themes & appearance | Full | Full | Full |
| Exports, dev tools, regressions | Full | — | — |

## 2. A new name

The name is private and non-commercial, so there are no trademark worries.

| Name | Why |
|---|---|
| **Escudo** | The old Portuguese currency, and "shield": the flat in Lisbon, and data kept safe. |
| **Kitty** | The household pot two people pay into. British, warm, and literally what the app tracks. |
| **Almanac** | A yearly record that also forecasts: history since 2020, forecast and tax years. |
| Mealheiro | Portuguese for piggy bank. Lovely, but hard to say for English speakers. |
| Hearth | The home as the centre of the household's money. |
| Tally | Counting up and keeping score; short; works as a verb ("tally the month"). |
| Ledger & Key | The books, plus the key (privacy, sharing levels). A bit long for an icon label. |
| Payday | The app's months run payday to payday. Too narrow for property and tax. |
| Moneta | The Roman goddess whose temple minted coins; the root of "money". |
| Keel | What keeps the household steady ("on an even keel"). |
| Quire | An old word for a book of accounts. Obscure but distinctive. |
| Cofre | Portuguese for strongbox: short, and the privacy layer in one word. |
| Two Purses | Two people, shared and private money: exactly the access model. |
| Florin | An old coin used across Europe; elegant, and neutral between pound and euro. |
| Nest | The nest egg and the home. Very common as a name, though. |

**Top 3:** Escudo, Kitty, Almanac.

**Recommendation: Escudo.**
- It ties the two countries your money lives in to the thing this work adds: a shield over shared and
  private data.
- It reads well as "Escudo" under an icon.
- It has a natural symbol: the cifrão (the escudo sign "$" with two strokes, as in "1$50").

**Icon direction for Escudo:**
- **Shape:** a rounded heater-shield silhouette, centred on a deep Atlantic-blue ground. The blue is the
  Classic accent darkened, so it matches the app's tint.
- **Inside the shield:** a cifrão drawn as one continuous line. It doubles as the three rising bars of
  today's icon if you prefer continuity: the bars become the cifrão's strokes.
- **Layers (Icon Composer, iOS/macOS 26):** ground, a Liquid Glass shield, a white glyph. It reads in the
  default, dark, clear and tinted icon modes.
- **Never:** coins, piggy banks or pound signs.
- Same icon on all three platforms. The Mac version keeps the rounded square.

## 3. Private distribution

| Option | Cost | Expiry | Updates | CloudKit / push / Sign-in | Verdict |
|---|---|---|---|---|---|
| **Apple Developer Program + TestFlight (internal)**, iPhone/iPad | Paid membership (≈ £79 / $99 a year) | Each build lasts 90 days; renew the membership yearly | Upload, then TestFlight installs it on all four devices; no review for internal testers | Yes | **Recommended for iOS** |
| **Developer ID + notarisation**, Mac | Same membership | None per build. Certificates last 5 years; notarised builds keep working | Your `install-app.sh` adds sign, notarise and staple | Yes: CloudKit and push work with Developer ID and a provisioning profile | **Recommended for the Mac** |
| TestFlight for Mac | Same membership | 90 days per build | TestFlight | Yes | Fine, but needless churn for the hub Mac |
| Ad hoc (registered devices) | Same membership | Profile lasts 1 year; up to 100 devices per type | Manual install (Xcode, Apple Configurator or a web link) every time | Yes | Works, but every update is manual |
| Free account, Xcode direct install | Free | **7 days**; at most 3 apps per device | Re-install from Xcode weekly, with the device connected | **No** CloudKit, no push, no App Groups (widgets) | Not viable |

**Recommendation: join the Apple Developer Program** as an individual, under your own Apple Account.
- **iPhone and iPad:** ship through TestFlight with both of you as internal testers. Your wife needs to
  be a user in your App Store Connect team; give her the least-privileged role.
- **Mac:** ship as a notarised Developer ID build through an updated `install-app.sh`.
- **The 90-day TestFlight expiry:** a scheduled build (Xcode Cloud's included hours, or a monthly
  reminder) uploads a fresh build before it bites.
- **Other things the membership unlocks:**
  - the team signature that upgrades the Mac's Touch ID unlock to a Keychain-bound item (auth spec §8);
  - App Groups for widgets;
  - CloudKit.
- **Two private-distribution routes don't fit:** the App Store's "unlisted app" needs review and a public
  listing page, and Custom Apps need Apple Business Manager.

## 4. Build order

Each step is its own plan and branch, rehearsed on a copy, merged only when green.

0. **Prerequisites:**
   - join the Developer Program;
   - register the bundle IDs (`com.personal.budget`, `.ios`, widget, share extension), the App Group and
     the CloudKit container;
   - switch the Mac build to Developer ID signing.
1. **Desktop authentication,** per the auth spec. Build it with the requested change §11.6
   (`localCredential`) already in, because it is cheapest now.
2. **BudgetCore on iOS:**
   - add the iOS platform;
   - move decision logic out of `App/DocumentImport` into BudgetCore;
   - add the `ActualsSource` seam (transactions only for now);
   - the iOS snapshot harness.
3. **Sync foundation (Mac only):**
   - `syncRecord`, `SyncSchema`, translators, staging;
   - the migration rehearsal on a copy;
   - upload to the development container;
   - round-trip tests with a second simulator.
4. **iPhone app, read-only, for the admin:** Home, Month, Accounts, Property, Search, lock.
5. **Sharing levels and private zones,** before anyone else joins, so private accounts are never shared
   even once.
6. **Household:**
   - invite and member onboarding;
   - permissions and the Mac's re-validation;
   - the iPhone's quick edits, widgets and notifications.
7. **iPad app:** sidebar and read screens, then Categorise, Recharges (Mail), Documents and Missing
   evidence.
8. **iPad import:** the import lease, Inbox and share extension, the review, Undo. Last, because it is
   the riskiest write path.
9. **Rename and icon,** once the name is chosen. This is cosmetic and can happen at any point after step
   0.

## 5. Decisions for the user

1. Accept the changes requested to the authentication spec (sync spec §11):
   - iCloud identity instead of Sign in with Apple;
   - no app password on mobile;
   - permissions table;
   - credentials kept local-only.
2. Join the Apple Developer Program now. It's needed from step 0 onward.
3. Pick the name (my recommendation: Escudo).
4. Turn on Advanced Data Protection on both Apple Accounts. The trade-off is that a recovery key or
   recovery contact becomes mandatory.
5. Default sharing level for the existing accounts: everything stays "Everything" until you change it
   in step 5.
