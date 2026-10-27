# Step 10 spike: in-app browser AutoFill and PDF capture (findings)

Date: 2026-10-27. Throwaway SwiftUI iPad app plus XCUITest, run headless on a dedicated iPad Pro 11" (M5) simulator, iOS 26.4 runtime, Xcode 27.1. All pages came from a local fixture server on `http://localhost:8765`: a login form, a PDF sent as `Content-Disposition: attachment`, a PDF sent inline (`application/pdf`), a form POST that returns a PDF, a `blob:` PDF, and a 302 redirect to an HTML error page. The test credential (`alex.test` for `localhost`) was added through the simulator's Passwords app. No real sites, no real Keychain. The spike code and the simulator were deleted afterwards.

Evidence came from the accessibility tree that XCUITest dumped at each step. In that tree the keyboard's Passwords key is `Image identifier: 'kb-autofill-key'`, and a saved login appears as a QuickType item labelled `password for localhost / alex.test`. Headless simulator screenshots don't draw the keyboard, so the tree is the evidence.

## Results

| Question | Result | Evidence |
|---|---|---|
| AutoFill in a plain `WKWebView` (no entitlement), password saved for the host | **No.** The Passwords key and the saved-login suggestion are both missing, on the username field and on the password field. The input assistant bar only shows undo, redo and paste. | `kb-autofill-key` 0, `alex.test` 0 (credential saved). It was also 0 before the credential existed. |
| Same, with `webcredentials:localhost` entitlement | **No change.** The entitlement was embedded (it is in `Spike.app-Simulated.xcent` and the binary). Without an `apple-app-site-association` file served by the site it does nothing, and Mango can't get that file onto third-party sites. | `kb-autofill-key` 0, `alex.test` 0 |
| Control: native `SecureField` (`.textContentType(.password)`) in the same app | Passwords key shown | `kb-autofill-key` 1 |
| Control: same page in Safari | Passwords key shown, plus the suggestion "password for localhost alex.test" and a "Fill Password" sheet on the username field | `kb-autofill-key` 1, `alex.test` 1 |
| `SFSafariViewController` hosted in the app | **Yes.** Passwords key and the saved-login suggestion appear. The keyboard belongs to the `com.apple.SafariViewService` process, not the app. | view-service tree: `kb-autofill-key` 1, `alex.test` 1 |
| `WKDownload`: attachment GET | Captured, starts with `%PDF-` | `[attachment GET] captured …statement-attach.pdf head=%PDF-` |
| `WKDownload`: inline `application/pdf` GET | Captured (the response policy returns `.download`) | `[inline application/pdf GET] captured` |
| `WKDownload`: POST form submit | Captured | `action POST /download` → `captured …statement-post.pdf` |
| `WKDownload`: `<a download>` and `blob:` URL | Both captured (`shouldPerformDownload=true`) | `[blob: URL] captured …blob-statement.pdf head=%PDF-` |
| Redirect to HTML error page | Not captured. It is shown as a page. | `response /error.html mime=text/html -> allow` |
| Tray attributes read back | `fileProtection = completeUntilFirstUserAuthentication` and `isExcludedFromBackup = true` on both the file and the tray directory. Note: `attributesOfItem[.protectionKey]` reads back `nil` on the simulator, so read `URLResourceValues.fileProtection` instead. | `protection(rv)=NSURLFileProtectionCompleteUntilFirstUserAuthentication excludedFromBackup=true trayExcluded=true` |
| `WKWebsiteDataStore.default().removeData(all, .distantPast)` | Clears cookies: `whoami` goes from signed-in to signed-out, cookies `["session"]` → `[]` | sitedata log |
| `WKWebsiteDataStore.nonPersistent()` as private browsing | Works. `isPersistent=false`. Signing in there leaves the default store signed out. | `privateCookies=["session"] defaultCookies=[]` |
| `SFSafariViewController` download | The attachment opens a file page ("statement-attach.pdf · Open in Preview · More…"). The app gets **no programmatic hook**. | view-service tree |
| `SFSafariViewController` → More… → Mango (PDF document type, `LSHandlerRank Alternate`) | The app appears in the share sheet. Tapping it delivers the file to `onOpenURL` as `Documents/Inbox/statement-attach.pdf` (starts with `%PDF-`). | `onOpenURL statement-attach.pdf isFile=true head=%PDF-` |
| `SFSafariViewController` cookies | Survive an app relaunch. `SFSafariViewController.DataStore.default.clearWebsiteData` clears them: signed-in becomes signed-out. | `relaunch=signed-in afterClear=signed-out` |

## Decision: NO-GO for the `WKWebView` in-app browser

The brief's GO rule needs AutoFill in-app, and `WKWebView` doesn't offer it for third-party sites with or without the entitlement. Downloads would have been fine.

**Chosen approach: `SFSafariViewController` + share-in.** This is a refinement of the pre-decided Safari fallback and uses the same ingest path. "Open site" presents the saved URL in `SFSafariViewController`, where Passwords AutoFill is native. The statement comes back into Mango through **More… / Share ▸ Mango**, which arrives in `onOpenURL` because Mango registers a PDF document type. The tray also gets a Files-picker (`.fileImporter`) button. Opening the site in Safari itself (`UIApplication.open`) stays available as a secondary action: it uses the same share-in path, and the user's Safari session is there. Everything downstream consumes `DownloadsTray.ingest(fileAt:…)`, so nothing else in the plan changes. `ASWebAuthenticationSession` is not used.

Task 5 notes:
- Share-in lands in `Documents/Inbox/`, which is backed up. `ingest` must move the file into the tray and delete the Inbox copy.
- Check the `%PDF-` magic before accepting a file: a site can send an HTML error page as an attachment.
- Sign-out calls `SFSafariViewController.DataStore.default.clearWebsiteData` and waits for its completion handler before presenting again.
- There is no private mode for `SFSafariViewController`. Clearing on sign-out is the control.
- Mango stores no passwords or cookies. The view service holds the session.

## Reference code that worked

```swift
// Share-in (chosen path): Info.plist CFBundleDocumentTypes = [{CFBundleTypeName: PDF, LSHandlerRank: Alternate,
// LSItemContentTypes: [com.adobe.pdf]}]; the file arrives at Documents/Inbox/<name>.pdf
.onOpenURL { url in /* DownloadsTray.ingest(fileAt: url) — move out of Inbox */ }
SFSafariViewController(url: savedSite.url)                       // AutoFill works here
SFSafariViewController.DataStore.default.clearWebsiteData { … }  // sign-out

// Tray attributes (both read back on the simulator)
try fm.createDirectory(at: tray, withIntermediateDirectories: true,
                       attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
var rv = URLResourceValues(); rv.isExcludedFromBackup = true
try tray.setResourceValues(rv)
try fm.moveItem(at: incoming, to: dest)
try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dest.path)
try dest.setResourceValues(rv)
dest.removeAllCachedResourceValues()
let check = try dest.resourceValues(forKeys: [.fileProtectionKey, .isExcludedFromBackupKey])  // not attributesOfItem

// WKWebView capture (proven, but not used because of AutoFill)
func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction) async -> WKNavigationActionPolicy {
    a.shouldPerformDownload ? .download : .allow }                          // <a download>, blob:
func webView(_ w: WKWebView, decidePolicyFor r: WKNavigationResponse) async -> WKNavigationResponsePolicy {
    let cd = (r.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
    return (r.isForMainFrame && (r.response.mimeType == "application/pdf" || cd.hasPrefix("attachment")))
        || !r.canShowMIMEType ? .download : .allow }
func webView(_ w: WKWebView, navigationResponse: WKNavigationResponse, didBecome d: WKDownload) { d.delegate = self }
func download(_ d: WKDownload, decideDestinationUsing r: URLResponse, suggestedFilename n: String) async -> URL? {
    tempDir(for: d).appending(path: n) }                      // move into the tray in downloadDidFinish
// didFailProvisionalNavigation code 102 ("Frame load interrupted") is expected when a response becomes a download
```

## What the simulator cannot prove: one real-device check

The simulator has no iCloud Keychain, no Face ID prompt on fill, and no third-party bank login pages. **Check on the real iPad after Task 5:** in Mango, open a saved site (it opens in `SFSafariViewController`). Tap the password field and confirm the Passwords key offers the iCloud Keychain login and fills it after Face ID. Then download one statement, tap More… ▸ Mango, and confirm it shows up in the tray.
