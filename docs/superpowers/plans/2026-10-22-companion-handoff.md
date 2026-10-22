# Handoff: companion apps, sync, access, Mango (from the cloud session, 2026-10-22)

The companion-apps work was done in a separate cloud session (no Mac, no Xcode), alongside the
desktop session that wrote the authentication spec. This file carries its state over so one session
can continue. Everything it refers to is on branch `claude/budget-ios-companion-spec-bi3dh9`. The Mac session has
already continued on it: the identifier move to `ubberninja.mango` and the import commits.
`companion-specs` only has the older cloud-session state. **Nothing here is merged into `main`
yet.**

## What exists

| File | What |
|---|---|
| `docs/superpowers/specs/2026-10-22-companion-apps-overview.md` | Index; feature × device matrix; names → **Mango** (§2.4 icon, §2.5 rename scope); private distribution and membership-lapse impact (§3); build order (§4); decisions (§5) |
| `docs/superpowers/specs/2026-10-22-sync-and-access-design.md` | See the table below |
| `docs/superpowers/specs/2026-10-22-iphone-app-design.md` | iPhone screens, widgets, notifications, states, tests |
| `docs/superpowers/specs/2026-10-22-ipad-app-design.md` | iPad: sidebar, import review, categorise, monthly recharges (Mail), documents, states, tests |
| `docs/design/mango-icon.svg` | Icon master. One group per Icon Composer layer. Final colouring approved by the user. |
| `docs/superpowers/plans/2026-10-22-step0-developer-setup.md` | Build step 0 checklist (parts A web, B Mac, C verify) |
| Step 0 repo changes (commit `1ba1e83`) | `Config/Signing.xcconfig` (+ `.local.example`, git-ignored local file); `App/Mango.entitlements`; `project.yml` configFiles + `CLOUDKIT_ENVIRONMENT`; `scripts/install-app.sh` Developer ID / notarise path; `scripts/render-snapshots.sh` always locally signed |

The sync-and-access spec covers:

| § | Topic |
|---|---|
| §3 | CloudKit architecture |
| §3.1 | Two people on one Mac: one macOS user each |
| §4 | `syncRecord` UUID side table |
| §5 | Conflicts, import lease, batches |
| §6 | Access control: sharing levels and permissions |
| §8 | Migration |
| §9 | Security |
| §9.1 | App-side document encryption |
| §11 | Changes to the auth spec, **accepted by the user** |
| §13 | Mac-hub fallback without a membership |

**Mockups** (private to the user, a claude.ai design canvas):
https://claude.ai/artifact/4bdRGqbyqKA1vQPwBLCYhZ. Its pages are Icon, Feature × device, iPhone (9),
iPad (6) and Mac sign-in (2). The small icons inside the lock and notification mockups are a flat
stand-in, not the final colouring.

## Decisions the user made (all 2026-10-21/22)

**Who uses what**
- One household Mac. The wife uses an iPhone and an iPad with her own Apple Account; the user uses all
  three. Statement import is in scope on the iPad.
- **iPhone:** read plus quick edits (categorise, note, receipt photo, accept a rent/recharge split,
  update a manual balance).
- **iPad:** everything on the iPhone, plus import, categorise, recharges, and adding or editing your own
  accounts.
- **Mac only:** forecast, tax, complex set-up.
- **The Mac app supports both people,** each on their own macOS user and Apple Account. CloudKit can only
  act as the logged-in macOS user, so real privacy needs separate macOS users.

**Sync and security**
- Sync is **CloudKit**, not Supabase or a file in iCloud Drive. The transport is built swappable; the Mac
  hub plus SideStore (§13) is the fallback if the membership lapses.
- The user is already a Developer Program member and may not renew every year. Impact is in overview
  §3.1: the Mac is fine, the mobile apps need the membership, no data is lost.
- **Advanced Data Protection isn't available in the UK.** So documents are encrypted by the app (§9.1),
  and fields use CloudKit's `encryptedValues`.

**Access**
- **Access has two layers.**
  - Sharing levels per account, set by the owner: Everything / Category totals / Balance only / Hidden.
  - Permissions per area (None / View / Edit), set by the admin.
- **Privacy belongs to the owner:** the admin can't see the other person's private data.
- **"Category totals" counts** in the budget and the forecast.
- **The starting level is Category totals** for personal accounts. Joint and property accounts and tax
  years start at Everything. That last part is the cloud session's reading of the user's earlier "flat
  and taxes fully transparent"; it hasn't been explicitly confirmed.

**Authentication**
- All the changes requested to the authentication spec are accepted (sync spec §11):
  1. iCloud identity instead of Sign in with Apple.
  2. No app password on mobile.
  3. Privacy with sync.
  4. A `memberPermission` table.
  5. One macOS user each.
  6. A `localCredential` table: password hashes never sync.
  7. Attribution through `syncRecord`.
  8. Copy says "Mango".

  **They still need folding into `docs/superpowers/specs/2026-10-21-authentication-design.md`.**

**Name and icon**
- **The name is Mango** on every device, including the Mac.
- **Identifiers changed during step 0** (`1688dcc`), because `group.com.personal.budget` was taken. They
  are now `ubberninja.mango` (Mac), `ubberninja.mango.ios` (+ `.widgets`, `.share`),
  `iCloud.ubberninja.mango` and `group.ubberninja.mango`. `AppIdentity.copyLegacyPreferencesOnce`
  carries the old UserDefaults across.
- **Unchanged:** the data folder `Application Support/Budget`, the module `BudgetCore`, and the UTType
  id and log subsystem.
- "Budget" stays where it means the budget grid or plan.
- The rename ships with build step 1.
- **The icon** is the user's chosen style: a glossy mango drawn as original vector artwork. The user's
  reference images were watermarked pngtree previews, which aren't usable.
  - The deep red-orange follows the lower-right curve; the green is barely there; navy ground.

## Where things stand

- **Specs: complete. The user has nothing open on them.**
- **Build step 0: in progress on the Mac.**
  - Identifiers are registered under `ubberninja.mango`.
  - Check the checklist and `git log` for what's verified: the notarised `/install`, `spctl`, the
    entitlements.
- **Build order after that** (overview §4):
  1. Desktop authentication + the Mango rename, with `localCredential` from the start.
  2. BudgetCore on iOS, plus moving the import-centre logic out of `App/DocumentImport`.
  3. Sync foundation on the Mac, rehearsed on a copy, with a swappable transport.
  4. Read-only iPhone app.
  5. Sharing levels, before the wife joins.
  6. Household invite, permissions, iPhone quick edits, widgets and notifications.
  7. iPad screens.
  8. iPad import.

## Risks to check as you go

- **Old identifiers in the specs.** The companion specs now use `ubberninja.mango` everywhere; only
  intentional historical mentions remain. The auth spec on `main` predates the move: check it when you
  fold in sync spec §11.
- **Push for Developer ID.** Untested. If the Developer ID export rejects push, drop it on the Mac;
  sync can poll.
- **UK and encrypted fields.** At step 0 or 3, confirm that CloudKit `encryptedValues` stay end-to-end
  for UK accounts without ADP (sync spec §9). There is a fallback if not.
- **App Store Connect name.** "Mango" is taken store-wide; use e.g. "Mango Household Budget" for the
  record. The display name on devices stays Mango.

## How the user likes to work (learnt in the cloud session)

- Give recommendations, not surveys. Ask one question at a time, and only when it changes the design.
- Never write `~/Library/Application Support/Budget/budget.sqlite` or the Evidence folder. Rehearse on
  copies, with backups before migrations.
- No personal data in commits: tests are synthetic; no team IDs, emails or figures.
- Edits save only on Save. No figure ever wraps or truncates. Follow the design system (ui-polish spec
  §1/§6).
- Merge to `main` only when asked.
