import XCTest
@testable import BudgetCore

/// The words every sync status shows (plan step 4, Task 12's copy; brought forward by Task 7 for Home's status line
/// and Needs attention): one line each, waiting never worded as a failure.
final class SyncStatusCopyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testEveryStatusHasCopy() {
        let cases: [(SyncStatus, String, SyncStatusCopy.Tone)] = [
            (.off, "Sync is off", .neutral),
            (.idle(lastSync: nil), "Not synced yet", .neutral),
            (.idle(lastSync: now.addingTimeInterval(-300)), "Up to date · 5 minutes ago", .neutral),
            (.syncing(.pulling), "Checking for changes…", .neutral),
            (.syncing(.pushing), "Sending changes…", .neutral),
            (.waitingForKey(since: now), "Waiting for the household key from iCloud Keychain", .neutral),
            (.offline(since: now, retryAt: now.addingTimeInterval(37)), "Offline · trying again in 37 seconds", .amber),
            (.offline(since: now, retryAt: nil), "Offline", .amber),
            (.needsAttention(held: 3, lastSync: nil), "3 changes need attention on the Mac", .amber),
            (.needsAttention(held: 1, lastSync: nil), "1 change needs attention on the Mac", .amber),
            (.unavailable(.noICloudAccount), "Sign in to iCloud to sync", .amber),
            (.unavailable(.quotaExceeded), "iCloud storage is full", .amber),
            (.failed(reason: "the database couldn't be read"), "Sync stopped — will try again", .amber),
        ]
        for (status, text, tone) in cases {
            let copy = SyncStatusCopy.text(status, now: now)
            XCTAssertEqual(copy.text, text, "\(status)")
            XCTAssertEqual(copy.tone, tone, "\(status)")
        }
    }

    /// A failure's reason (which may quote an error) never reaches the status line; it is only the details.
    func testAFailureReadsAsStoppedAndKeepsItsReasonForTheDetails() {
        let status = SyncStatus.failed(reason: "SQLite error 1: query failed")
        let copy = SyncStatusCopy.text(status, now: now)
        XCTAssertEqual(copy.text, "Sync stopped — will try again")
        XCTAssertFalse(copy.text.lowercased().contains("error") || copy.text.lowercased().contains("failed"))
        XCTAssertEqual(SyncStatusCopy.detail(status), "SQLite error 1: query failed")
        XCTAssertNil(SyncStatusCopy.detail(.offline(since: now, retryAt: nil)))
    }

    /// A retry time already past (the status not yet updated) reads "shortly", never "5 seconds ago".
    func testARetryTimeInThePastReadsShortly() {
        XCTAssertEqual(SyncStatusCopy.text(.offline(since: now, retryAt: now.addingTimeInterval(-5)), now: now).text,
                       "Offline · trying again shortly")
        XCTAssertEqual(SyncStatusCopy.text(.offline(since: now, retryAt: now), now: now).text, "Offline · trying again shortly")
    }

    func testWaitingForKeyIsNeutralAndNeverAnError() {
        let copy = SyncStatusCopy.text(.waitingForKey(since: now), now: now)
        XCTAssertEqual(copy.tone, .neutral)
        for word in ["error", "failed", "failure"] {
            XCTAssertFalse(copy.text.lowercased().contains(word))
        }
    }

    func testNoStatusSaysErrorOrFailed() {
        let statuses: [SyncStatus] = [.off, .idle(lastSync: now), .syncing(.pulling), .waitingForKey(since: now),
                                      .offline(since: now, retryAt: nil), .needsAttention(held: 2, lastSync: now),
                                      .unavailable(.noICloudAccount), .failed(reason: "an error: the read failed")]
        for status in statuses {
            let text = SyncStatusCopy.text(status, now: now).text.lowercased()
            XCTAssertFalse(text.contains("error") || text.contains("failed") || text.contains("failure"), text)
        }
    }

    /// What Home's Needs attention lists: everything but the quiet states (off, up to date, syncing).
    func testProblemsAreTheStatusesThatAreNotQuiet() {
        XCTAssertFalse(SyncStatusCopy.isProblem(.off))
        XCTAssertFalse(SyncStatusCopy.isProblem(.idle(lastSync: nil)))
        XCTAssertFalse(SyncStatusCopy.isProblem(.syncing(.pulling)))
        XCTAssertTrue(SyncStatusCopy.isProblem(.waitingForKey(since: now)))
        XCTAssertTrue(SyncStatusCopy.isProblem(.offline(since: now, retryAt: nil)))
        XCTAssertTrue(SyncStatusCopy.isProblem(.needsAttention(held: 1, lastSync: nil)))
        XCTAssertTrue(SyncStatusCopy.isProblem(.unavailable(.quotaExceeded)))
        XCTAssertTrue(SyncStatusCopy.isProblem(.failed(reason: "x")))
    }

    // MARK: Task 12: the phone's sync states

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// "Offline · showing data from <time>." — the time alone today, the day and time before; no "N changes" on a
    /// read-only phone.
    func testOfflineBannerSaysWhenTheDataIsFrom() {
        // 1_800_000_000 is 15 Jan 2027, 08:00 UTC.
        XCTAssertEqual(SyncStatusCopy.offlineBanner(lastSync: now.addingTimeInterval(-3_600), now: now, calendar: utc),
                       "Offline · showing data from 07:00.")
        XCTAssertEqual(SyncStatusCopy.offlineBanner(lastSync: now.addingTimeInterval(-3 * 86_400), now: now, calendar: utc),
                       "Offline · showing data from 12 Jan, 08:00.")
        XCTAssertEqual(SyncStatusCopy.offlineBanner(lastSync: now.addingTimeInterval(-400 * 86_400), now: now, calendar: utc),
                       "Offline · showing data from 11 Dec 2025, 08:00.")
        XCTAssertEqual(SyncStatusCopy.offlineBanner(lastSync: nil, now: now, calendar: utc),
                       "Offline · showing what's on this iPhone.")
        for text in [SyncStatusCopy.offlineBanner(lastSync: now, now: now, calendar: utc),
                     SyncStatusCopy.offlineBanner(lastSync: nil, now: now, calendar: utc)] {
            XCTAssertFalse(text.contains("change"), text)
        }
    }

    func testFirstDownloadCountsTheRecordsSoFar() {
        XCTAssertEqual(SyncStatusCopy.firstDownload(received: 0), "Downloading the household's records…")
        XCTAssertEqual(SyncStatusCopy.firstDownload(received: 1), "Downloading the household's records… 1 so far")
        XCTAssertEqual(SyncStatusCopy.firstDownload(received: 12_345), "Downloading the household's records… 12,345 so far")
    }

    /// Settings' security line: sealed, or waiting (never an error), or nothing to say while sync is off.
    func testHouseholdKeyLine() {
        XCTAssertEqual(SyncStatusCopy.householdKey(held: true), "Records sealed with the household key")
        XCTAssertEqual(SyncStatusCopy.householdKey(held: false), "Waiting for the household key from iCloud Keychain")
        XCTAssertEqual(SyncStatusCopy.householdKey(held: nil), "Sync is off")
        XCTAssertEqual(SyncStatusCopy.householdKey(held: false),
                       SyncStatusCopy.text(.waitingForKey(since: now), now: now).text, "the same words as the status")
    }
}
