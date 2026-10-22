# Build step 0: developer set-up

**Spec:** `docs/superpowers/specs/2026-10-22-companion-apps-overview.md` §3 (distribution) and §4
(build order, step 0). Read it first.

Goal: the Mac app is signed by your team, notarised and installed with no expiry, and every identifier
the companions will need is registered. No app behaviour changes, and the database isn't touched.

## Done in the repo (this commit)

- `Config/Signing.xcconfig`: included by the Mac target (`project.yml` `configFiles`). It pulls in an
  optional, git-ignored `Config/Signing.local.xcconfig` holding your team ID.
  - **Without that file, the build is exactly as before:** signed to run locally, no entitlements.
- `Config/Signing.local.xcconfig.example`: copy it, then fill in your team ID.
- `App/Mango.entitlements`, used only when a team is set:
  - the iCloud container `iCloud.com.personal.budget` with CloudKit;
  - the CloudKit environment: Development for Debug, Production for Release, which Developer ID
    requires;
  - the data-protection keychain group, for the auth spec's Touch ID upgrade (§8).
- `scripts/install-app.sh`:
  - **with a team:** archive → export as Developer ID → notarise (`notarytool`, keychain profile
    `mango-notary`) → staple → install → Gatekeeper check;
  - **without a team:** unchanged.
- `scripts/render-snapshots.sh`: snapshot builds stay signed to run locally whatever the team settings.
  They use their own bundle id, which has no profile.
- **Not verified on macOS:** the session that wrote this had no Xcode. Both scripts pass `zsh -n`. Step
  C below is the real test.

## A. On developer.apple.com (you, about 15 minutes)

Certificates, Identifiers & Profiles:

1. **Identifiers ▸ App IDs**, explicit:
   - `com.personal.budget`, the Mac app. Capabilities: iCloud (CloudKit, with the container below),
     Push Notifications.
   - `com.personal.budget.ios`, the iPhone/iPad app. Capabilities: iCloud (CloudKit), App Groups, Push
     Notifications.
   - `com.personal.budget.ios.widgets` and `com.personal.budget.ios.share` (App Groups).
2. **Identifiers ▸ iCloud Containers:** `iCloud.com.personal.budget`. Assign it to both app IDs.
3. **Identifiers ▸ App Groups:** `group.com.personal.budget`. Assign it to the three iOS IDs.
4. **Certificates:** a **Developer ID Application** certificate. Xcode can create it: Settings ▸
   Accounts ▸ your team ▸ Manage Certificates ▸ + ▸ Developer ID Application.
5. **If an identifier is refused as "already in use":** bundle IDs and containers are unique across all
   developers, and `com.personal` is a common prefix. Then:
   - use your own reverse-DNS prefix instead (e.g. `com.<yourname>.mango`) for all of them;
   - tell me, and I'll change `project.yml`, the entitlements and the specs;
   - nothing else depends on it: the data folder (`Application Support/Budget`) is a fixed path. Only
     the app's preferences (theme, appearance) would start fresh, and the app can copy those across
     once.

## B. On your Mac (you, about 10 minutes)

1. `cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig`, then set
   `DEVELOPMENT_TEAM` to your Team ID (Account ▸ Membership details).
2. **The notarisation profile.** Use an app-specific password from appleid.apple.com (Sign-In and
   Security ▸ App-Specific Passwords), not your Apple Account password:
   ```
   xcrun notarytool store-credentials mango-notary --apple-id <your Apple Account email> --team-id <Team ID>
   ```
   It prompts for the password and stores it in your login keychain. It never goes in the repo.
3. **App Store Connect:** create the iOS app record now, so TestFlight is ready for build step 4.
   - Platform iOS, bundle ID `com.personal.budget.ios`.
   - App Store Connect names are unique across the whole store, so "Mango" will be taken. Use e.g.
     "Mango Household Budget". The name under the icon on your devices stays "Mango".
   - Users and Access: add your wife's Apple Account with a limited role, e.g. Customer Support, so she
     can be an internal TestFlight tester.

## C. Verify (you, or me in a session on your Mac)

1. Quit the app, then run `/install` (or `scripts/install-app.sh`).
   - Expect: archive, export, "Notarising…", then a notarytool status `Accepted`.
   - Expect: `spctl` printing `accepted` and `source=Notarized Developer ID`.
2. Open Budget from Applications and check that it starts normally on your data. With no database
   change in this step, this is just a launch.
3. `codesign -d --entitlements - /Applications/Budget.app` lists the iCloud container and the keychain
   group.
4. **If the export fails on a capability** (e.g. push for Developer ID): remove that capability from
   the Mac app ID and the entitlements. Sync can poll instead of push on the Mac. Report what happened
   so the spec records it.

## Then

Build step 1: desktop authentication, per `2026-10-21-authentication-design.md` plus the accepted
changes (sync spec §11). It includes `localCredential`, and the rename to Mango, whose icon comes from
`docs/design/mango-icon.svg` through Icon Composer.
