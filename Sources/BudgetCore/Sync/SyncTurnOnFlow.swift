import Foundation

/// What the Mac's "Turn on sync…" sheet and Settings ▸ Sync show at each point of `SyncTurnOn` (step 6 Task 13), and
/// every word of it. The sheet has two steps, each a section with its state: **1 Back up**, **2 Upload**; the blockers
/// are listed above them. It doesn't ask who owns each account (sync-ui, 2026-10-26): the upload's start confirms the
/// defaults (`SyncTurnOn.confirmOwnershipAtStart`) and each account's sharing is changed in the account itself. Only the person's own press of **Start upload** starts
/// the upload, and only with no blocker left; closing the sheet never stops a running upload, and reopening it shows the
/// stage kept in the database.
public enum SyncTurnOnFlow {
    public enum StepState: Equatable, Sendable {
        /// An earlier step comes first.
        case waiting
        /// This step is the one to do now.
        case current
        case done
    }

    /// What the sheet is doing now (its buttons wait meanwhile).
    public enum Work: Equatable, Sendable {
        case none
        case checking
        case backingUp
        case starting
    }

    public struct Facts: Equatable, Sendable {
        public var progress: SyncTurnOn.Progress
        public var blockers: [SyncTurnOn.Blocker]
        /// The iCloud checks behind `blockers` (keys, markers, the account) have answered.
        public var checked: Bool
        /// The real sync's status (`.off` while it isn't running).
        public var syncStatus: SyncStatus
        /// Why the real sync isn't running although the upload began (a different iCloud user, say); nil otherwise.
        public var syncRefusal: String?
        public var work: Work

        public init(progress: SyncTurnOn.Progress, blockers: [SyncTurnOn.Blocker], checked: Bool,
                    syncStatus: SyncStatus, syncRefusal: String? = nil, work: Work = .none) {
            self.progress = progress
            self.blockers = blockers
            self.checked = checked
            self.syncStatus = syncStatus
            self.syncRefusal = syncRefusal
            self.work = work
        }
    }

    public enum Tone: Equatable, Sendable {
        case neutral, amber
    }

    public struct Screen: Equatable, Sendable {
        /// The blockers' copy, above the steps (only before the upload begins).
        public var blockerLines: [String]
        public var backUp: StepState
        /// The backup's file name once made ("Backed up: …").
        public var backupLine: String?
        /// "Back up now" (or "Back up again") is enabled.
        public var canBackUp: Bool
        public var backUpButton: String?
        public var upload: StepState
        public var uploadLine: String?
        public var uploadTone: Tone
        /// "Start upload" is shown (before the upload began).
        public var showsStartUpload: Bool
        /// …and enabled: nothing blocks, the checks have answered, nothing else is running.
        public var canStartUpload: Bool
        /// Uploading: how far, 0…1 (nil otherwise).
        public var fraction: Double?
        /// "Check again": iCloud didn't answer the checks.
        public var showsCheckAgain: Bool
    }

    // MARK: Copy

    public static let sheetTitle = "Turn on sync"
    public static let sheetNote = "Mango backs up your data, then uploads everything to iCloud, sealed with keys only your devices hold."
    public static let blockersTitle = "Before sync can turn on:"
    public static let checking = "Checking iCloud…"
    public static let checkFailed = "Mango couldn't reach iCloud to check, so the upload can't start yet."
    public static let checkAgain = "Check again"
    public static let closeButton = "Close"
    public static let closingNote = "Closing this window doesn't stop the upload."

    public static let backUpTitle = "Back up"
    public static let backUpNow = "Back up now"
    public static let backUpAgain = "Back up again"
    public static let backingUp = "Backing up…"
    public static let backUpExplanation = "A full copy of your data beside it, before anything changes."
    public static func backedUp(fileName: String) -> String { "Backed up: \(fileName)" }

    public static let uploadTitle = "Upload"
    public static let startUpload = "Start upload"
    public static let starting = "Starting the upload…"
    public static let uploadWaiting = "After the backup."
    public static let uploadExplanation = "Nothing goes to iCloud until you press Start upload. Your accounts start shared as balance only, property accounts in full; change each one in Accounts."
    public static func uploading(sent: Int, total: Int) -> String { "Uploading \(sent) of \(total) records" }
    public static let uploadPaused = "Upload paused — it continues where it stopped."
    public static let uploadDone = "Your data is in iCloud."

    /// Settings ▸ Sync before the upload.
    public static let settingsButton = "Turn on sync…"
    public static let settingsOff = "Your data stays on this Mac. Turn on sync to keep it in iCloud for your iPhone."
    /// Settings ▸ Sync once the upload began: the sheet again, to watch it.
    public static let settingsShowUpload = "Show upload…"

    /// At launch, when this Mac's iCloud user isn't the one that turned on sync.
    public static let differentICloudUserAtLaunch =
        "This Mac is signed in to a different iCloud account from the one that turned on sync. Sign in to that account in System Settings, then open Mango again."
    /// At launch, until CloudKit says who is signed in (offline, say).
    public static let iCloudUserUnknown = "Waiting for iCloud to confirm who is signed in."

    // MARK: Rules

    /// Blockers the person can clear from here (sign in to iCloud, remove a test's key); the others need another build,
    /// another database or another person, so Settings ▸ Sync shows them instead of "Turn on sync…".
    public static func isFixable(_ blocker: SyncTurnOn.Blocker) -> Bool {
        switch blocker {
        case .strayHouseholdKey, .strayPrivateKey, .noICloudAccount, .differentICloudUser: return true
        case .notAdmin, .notAppDatabase, .wrongEnvironment, .noEntitlement, .demoDatabase, .syncedBefore: return false
        }
    }

    /// Settings ▸ Sync offers "Turn on sync…" when nothing blocks or only fixable blockers do; once the upload began it
    /// always offers the sheet again.
    public static func offersTurnOn(stage: SyncTurnOn.Stage, blockers: [SyncTurnOn.Blocker]) -> Bool {
        stage >= .uploading || blockers.allSatisfy(isFixable)
    }

    public static func screen(_ facts: Facts) -> Screen {
        let stage = facts.progress.stage
        let idle = facts.work == .none
        let started = stage >= .uploading
        // Neither a copy nor the demo, nor someone other than the admin, ever writes here.
        let mayWrite = !facts.blockers.contains(where: [.notAdmin, .notAppDatabase, .demoDatabase].contains)

        let isBackedUp = stage >= .backedUp
        let fileName = facts.progress.backupPath.map { URL(fileURLWithPath: $0).lastPathComponent }
        let backUpButton: String? = started ? nil : (facts.work == .backingUp ? backingUp : (isBackedUp ? backUpAgain : backUpNow))

        let upload: StepState
        var line: String?
        var tone = Tone.neutral
        var fraction: Double?
        switch stage {
        case .done:
            upload = .done
            line = uploadDone
        case .uploading:
            upload = .current
            if let refusal = facts.syncRefusal {
                line = refusal
                tone = .amber
            } else if case .offline = facts.syncStatus {
                line = uploadPaused
                tone = .amber
            } else {
                line = uploading(sent: facts.progress.sent, total: facts.progress.total)
            }
            fraction = facts.progress.total > 0 ? Double(facts.progress.sent) / Double(facts.progress.total) : 0
        default:
            upload = isBackedUp ? .current : .waiting
            line = facts.work == .starting ? starting : (isBackedUp ? uploadExplanation : uploadWaiting)
        }

        return Screen(
            blockerLines: started ? [] : facts.blockers.map(SyncTurnOn.text),
            backUp: isBackedUp ? .done : .current,
            backupLine: isBackedUp ? fileName.map { backedUp(fileName: $0) } : backUpExplanation,
            canBackUp: !started && idle && mayWrite,
            backUpButton: backUpButton,
            upload: upload,
            uploadLine: line,
            uploadTone: tone,
            showsStartUpload: !started,
            canStartUpload: !started && isBackedUp && facts.blockers.isEmpty && facts.checked && idle,
            fraction: fraction,
            showsCheckAgain: !started && !facts.checked && idle)
    }
}
