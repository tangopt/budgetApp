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
| Security check (FileVault, iCloud, document encryption) | Full | Full | Full |
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

### 2.1 More names (asked for, 2026-10-22)

| Name | Why |
|---|---|
| **Sixpence** | The silver sixpence in the bride's shoe ("…and a silver sixpence in her shoe"): a British wish for a married couple's prosperity. Small, lucky, two of you. |
| **Tuppence** | "Two pence": the two of you, cheeky and British ("put in your tuppence"). |
| **Azulejo** | Lisbon's tiles: many small squares that make one picture, like the category × pay-month grid. |
| Saldo | "Balance" in Portuguese: the one number every screen is about. |
| Tostão | An old Portuguese coin; "sem um tostão" means broke. Affectionately self-deprecating. |
| Caravel | The small Portuguese ship built for long voyages: nimble, and looking far ahead (the forecast). |
| Fado | Lisbon's song, and the word for fate: where the money is heading. |
| Larder | Where a household keeps its provisions. Homely and British. |

**Overall top 3:** Sixpence, Escudo, Azulejo.

**Recommendation now: Sixpence.**
- It's the one with a story about the two of you.
- It's British like your tax home, short under an icon, and warm rather than technical.
- Escudo stays the runner-up if you prefer the Portuguese link and the "shield".

**Icon direction for Sixpence:**
- **Ground:** deep navy, so the same tint family as the app.
- **The coin:** one silver coin seen almost face-on in Liquid Glass. Its milled edge is a ring of fine
  ticks.
- **On its face:** today's three rising bars, embossed, so the old icon lives on inside the new one.
- **Variants:** in tinted and clear modes the coin becomes a ring and the bars a single glyph. It must
  read at 16 pt in the Mac's menu bar and Spotlight.
- **No lettering** ("6d"), no shoes, no confetti.

### 2.2 Funny ones (asked for, 2026-10-22)

| Name | Why |
|---|---|
| **Moneypenny** | Bond's unflappable secretary: keeps everything in order and knows where every penny went. |
| **Quids In** | British for "in profit". Optimistic, cheeky. |
| **Ledger Zeppelin** | A whole lotta budget. |
| **The Damage** | "What's the damage?": the British way to ask for the bill. |
| **Pastel de Cash** | For a household with a flat in Lisbon. |
| Tosta Mista | The Portuguese ham-and-cheese toast: two fillings, one sandwich, i.e. joint finances. |
| Skint | British for broke. Honest. |
| Brassic | Also British for broke ("boracic lint", rhyming slang). |
| Sum of Us | "Some of us" do the categorising. |
| Where Did It Go? | The question every Month screen answers. |
| Penny Dreadful | For the months that read like a horror story. |
| Cha-Ching | Says what it does. |

**Funny favourite: Moneypenny.** It's a joke that wears a suit: it works as a daily app name without
getting old, and an icon of a single elegant penny, or a monogrammed "M", is easy.

### 2.3 Argentine ones (asked for, 2026-10-22)

| Name | Why |
|---|---|
| **Vaquita** | "Hacer una vaquita" means everyone chips in to a shared pot. It's the household kitty in Argentine. |
| **Plata** | Money in Argentina, silver, the Río de la Plata, and the root of the country's name (*argentum*). |
| **Tango** | It takes two. Two people, one budget, moving together. |
| **Mate** | Passed around a circle and shared. In Britain it means a friend. Works in both your countries. |
| Chanchito | The Argentine piggy bank. |
| Guita | Porteño slang for money ("la guita"). |
| Ombú | The pampas tree with deep roots and wide shade: what savings are for. |
| Pampa | Flat, endless horizon: the long forecast. |
| **Colchón** (funny) | The mattress every Argentine keeps dollars under. The app is a better mattress. |
| **Dólar Blue** (funny) | The parallel exchange rate. The app does exchange rates too, legally. |
| **Mango** (funny) | Slang for a peso: "no tengo un mango". The icon is a mango. |
| **Alfajor** (funny) | Two biscuits, one dulce de leche filling: joint finances. |
| Doce Cuotas (funny) | "Twelve interest-free instalments": the national pastime. |

**Argentine favourite: Vaquita.**
- It describes exactly what the app is for: two people's money in one pot, with each person's own
  share kept apart.
- It's affectionate and short.
- Its icon is obvious and fun: a small cow-shaped money box (a vaquita instead of a chanchito), white on
  navy, with a coin slot on its back and the three rising bars as its spots.

**Runner-up: Plata.** One word that ties Argentina, money and the "silver" of Sixpence together.

### 2.4 Decision: Mango (user, 2026-10-22)

**The app is called Mango on every device, the Mac included.** "No tengo un mango": Argentine for "I
haven't got a peso", which is exactly why you keep a budget.

**Icon** (canvas page "Icon: Mango"; master artwork `docs/design/mango-icon.svg`, one group per Icon
Composer layer):
- **Ground:** deep navy (`#16406A` → `#0A2440`), the app's tint family.
- **The artwork (revised by the user, 2026-10-22):** drawn after the user's reference image as original
  vector artwork. The reference is a watermarked stock preview, so it isn't used itself.
  - **The fruit (ripe, revised 2026-10-22):** a glossy, plump mango leaning right, with the rounded beak at the
    lower left, centred in the icon. A gradient runs from red-orange on the left (`#D93A1A` →
    `#EE6A1C`) through orange (`#FAA21E`) to gold (`#FFD43A`) and a touch of yellow-green on the right
    (`#D9D63A`). On top: a deep red blush upper left, a green flush lower right, darker edges for
    roundness, and a gloss highlight upper left.
  - **The stem:** curved, brown (`#7A4A22`), rising up and to the left.
  - **The leaf:** one broad leaf, deep green (`#5FB23E` → `#2A6E25`), with a pale midrib and veins. It starts
    at the stem and falls to the right over the shoulder of the fruit.
- **Appearances:** default, dark (near-black ground), tinted (a one-colour silhouette that takes the
  system tint), clear (a glass silhouette).
- **Small sizes:** below 32 px a simplified drawing drops the gloss, shading, shadow and leaf veins.
- **Never:** lettering, coins or currency signs. The same artwork everywhere; the system applies each
  platform's rounded shape.

### 2.5 What the rename touches (the Mac app included)

**User-facing (changes):**
- The product and display name: `project.yml` `name`/`PRODUCT_NAME` → Mango, so the app becomes
  `/Applications/Mango.app`. Bump `CURRENT_PROJECT_VERSION`, because macOS caches icons per bundle id
  and version (`project.yml` already notes this).
- The app-name copy:
  - the application menu ("Mango ▸ Settings…", "Mango ▸ Lock");
  - `LaunchView`'s title;
  - the lock screen ("Mango is locked");
  - messages that name the app ("Mango deletes its copy…", "Mango stops scanning it…");
  - the window title's fallback;
  - the UTType description ("Mango account reference").
- The app icon (`App/Assets.xcassets/AppIcon`, from the master artwork through Icon Composer).
- `scripts/install-app.sh`:
  - quit-check `pgrep -x Mango`;
  - install `Mango.app`;
  - **remove an old `/Applications/Budget.app` once**, unregistering it from Launch Services so
    Spotlight offers only Mango.
- `scripts/render-snapshots.sh` (the built app's path) and the `/install` skill's text.

**Kept on purpose, so nothing about the data moves:**
- **The bundle identifier `com.personal.budget`.** Changing it would orphan the Keychain items, the
  UserDefaults (Touch ID enrolment, themes) and the CloudKit container.
- **The data folder** `~/Library/Application Support/Budget/` (database, evidence library, backups).
  `AppEnvironment`, `EvidenceLibrary` and the command-line tools keep that path. A folder rename buys
  nothing and risks the data.
- **The CloudKit container** `iCloud.com.personal.budget`, the App Group `group.com.personal.budget`,
  the UTType identifier, the `BudgetCore` module, the target names in code, and the log subsystem.
- **The word "Budget" where it names the screen or the plan, not the app:** the Budget grid in the
  sidebar, the dashboard's "Budget ›" links, the "Budget" plan chip in the Forecast. The app is Mango;
  its budget is still a budget.

**When:** with build step 1 (desktop authentication). Its lock screen and setup copy are new anyway, and
the auth spec asks for them to say "Mango" (sync spec §11.8). The step is cosmetic and safe because no
identifier changes.

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

### 3.0 Without any membership (asked, 2026-10-22)
There is a path that needs no membership; it's in the sync spec's §13:
- **Sync through the household Mac** (Budget Hub, reachable away from home through Tailscale's free
  plan) instead of iCloud.
- **Install on iPhones and iPads with a free Apple Account through SideStore,** which re-signs the app
  every 7 days over home Wi-Fi.

The trade-offs: the Mac has to be awake for sync, there's no push, widgets may be unavailable, and there
is more to build. The data never leaves your devices. The sync transport is built to be swappable, so
the choice can wait until build step 3.

### 3.1 If the membership isn't renewed (asked, 2026-10-22)

The user is already a member and may not renew every year. What happens when it lapses:

| What | Effect |
|---|---|
| **Mac app (Developer ID, notarised)** | Keeps launching: notarised, timestamped builds aren't revoked when a membership ends. You can't sign or notarise new builds until you renew. Local builds (today's ad-hoc way) still work, but without CloudKit. |
| **iPhone and iPad (TestFlight)** | No new builds can be uploaded. Installed builds stop launching when they expire, at most 90 days after upload. In practice **the mobile apps need an active membership.** |
| **Sync (CloudKit)** | The data stays in iCloud. Expect sync to stop working for new builds, and treat it as unavailable until renewal. |
| **Your data** | **Nothing is lost.** Every device has a full local copy of what it can see. The hub Mac has the whole household plus your private data, keeps working offline, and keeps its backups. |
| **Free-account fallback** | Xcode installs that expire after 7 days, with no CloudKit. Not a real fallback for the companions. |

**What the design does about it (my call):**
- The apps treat "sync unavailable" like being offline, with a banner saying why.
- They never delete local data because sync stopped.
- On renewal, sync resumes from where it left off: changes made meanwhile upload normally.
- The Mac stays fully usable with no membership at all.
- **Before letting it lapse:** make sure the other person's private data is also on a device she keeps.
  Her iPad's TestFlight build will stop launching, and her private data isn't on your Mac. The app's
  "Export my data" (a Settings action on every device) saves her own encrypted backup file.
- **Cheapest way to stay safe:** renew yearly, and upload a TestFlight build every 60 days (a scheduled
  reminder or Xcode Cloud).

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
9. **Rename to Mango and the new icon:** done together with step 1 (§2.5).

## 5. Decisions for the user

Settled on 2026-10-22:
- **The changes requested to the authentication spec (sync spec §11) are accepted.** All seven, for the
  authentication spec's owner to fold in.
- **The user is already a Developer Program member,** and may not renew every year. The impact is in
  §3.1: the Mac is unaffected, the mobile apps need the membership, and no data is ever lost.
- **No Advanced Data Protection (not available in the UK).** The app encrypts documents itself instead
  (sync spec §9.1).
- **Two people on the Mac:** one macOS user each (sync spec §3.1).
- **Sync path: CloudKit for now.** The transport is built swappable; the Mac hub (sync spec §13) is the
  fallback if the membership lapses.

- **Name: Mango**, on every device including the Mac; icon designed (§2.4, §2.5).
- **Starting sharing level: Category totals** (sync spec §6.1, §8).

Nothing is open. Next is build step 0.
