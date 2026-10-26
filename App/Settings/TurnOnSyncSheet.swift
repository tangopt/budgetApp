// App/Settings/TurnOnSyncSheet.swift
import SwiftUI
import Combine
import BudgetCore
import GRDB
import MangoSync

/// "Turn on sync…" (step 6 Task 13, sharing spec §10, sync spec §8): Settings ▸ Sync's sheet for the real database.
/// Three steps, each a section with its state, the blockers listed above them (`SyncTurnOnFlow`, every word from
/// BudgetCore): **1 Back up** (`SyncTurnOn.backUp`, the file name shown), **2 Who owns each account?** (the ownership
/// sheet, only once backed up), **3 Upload** (only the person's Start upload begins it, with no blocker left; then the
/// progress, "paused" while offline, done). Closing the sheet never stops a running upload; reopening it reads the
/// stage again from the database.
@MainActor
final class TurnOnSyncModel: ObservableObject {
    @Published private(set) var facts: SyncTurnOnFlow.Facts
    /// The ownership sheet's rows while it is open.
    @Published var ownershipRows: [SharingSetup.Row]?
    @Published private(set) var adminName = ""
    @Published var error: String?

    private let environment: AppEnvironment
    private var watch: AnyCancellable?

    init(environment: AppEnvironment) {
        self.environment = environment
        facts = SyncTurnOnFlow.Facts(progress: SyncTurnOn.Progress(stage: .notStarted, backupPath: nil, total: 0, sent: 0),
                                     ownershipConfirmed: false, blockers: [], checked: false, syncStatus: .off, work: .checking)
        // The running upload's progress and status, live.
        watch = environment.realSync.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.followRealSync() }
        }
    }

    var screen: SyncTurnOnFlow.Screen { SyncTurnOnFlow.screen(facts) }

    private var dbQueue: DatabaseQueue { environment.dbQueue }

    private func followRealSync() {
        let sync = environment.realSync
        if let progress = sync.progress, progress.stage >= facts.progress.stage { facts.progress = progress }
        facts.syncStatus = sync.status
        facts.syncRefusal = sync.refusal
    }

    /// Everything the blockers need, again: the database (read only), the build, then iCloud (its account, user, keys
    /// and markers) in a build signed for the container.
    func refresh() async {
        if facts.work == .none { facts.work = .checking }
        defer { if facts.work == .checking { facts.work = .none } }
        do {
            try await TurnOnSteps.noteOwnersIfConfirmed(dbQueue)
            let local = try await TurnOnSteps.localFacts(dbQueue, signedInAppUserId: environment.session.currentAppUserId)
            adminName = try await dbQueue.read { db in
                try String.fetchOne(db, sql: "SELECT displayName FROM appUser WHERE isAdmin = 1 ORDER BY id LIMIT 1") ?? ""
            }
            let opened = environment.databasePath
            // The snapshot harness never asks iCloud or the Keychain.
            let entitled = !SnapshotMode.isActive && MacBuild.hasCloudKitEntitlement()
            var available = true
            var recordName: String?
            var keys: [SyncTurnOn.ZoneKeyFacts] = []
            var checked = true
            if entitled {
                do {
                    (available, recordName, keys) = try await TurnOnSteps.iCloudFacts(zones: local.zones)
                } catch {
                    checked = false
                    self.error = SyncTurnOnFlow.checkFailed
                }
            }
            let blockers = SyncTurnOn.blockers(
                isAdmin: local.isAdmin, isAppDatabase: MacBuild.isAppDatabase(openedPath: opened), isProduction: MacBuild.isProduction(),
                hasEntitlement: entitled, isDemoDatabase: MacBuild.isDemoDatabase(openedPath: opened), iCloudAvailable: available,
                iCloudUser: SyncTurnOn.iCloudUserCheck(signedIn: recordName, recorded: local.adminICloudUser),
                stage: local.progress.stage, turnOnKeyIds: local.turnOnKeyIds, keys: keys)
            facts.progress = local.progress
            facts.ownershipConfirmed = local.ownershipConfirmed
            facts.blockers = blockers
            facts.checked = checked
            if checked, error == SyncTurnOnFlow.checkFailed { error = nil }
            followRealSync()
        } catch {
            // Nothing stale may let Start upload through: unchecked until a refresh succeeds.
            facts.checked = false
            facts.blockers = []
            self.error = error.localizedDescription
        }
    }

    func backUp() async {
        guard screen.canBackUp else { return }
        error = nil
        facts.work = .backingUp
        defer { facts.work = .none }
        do {
            _ = try await TurnOnSteps.backUp(dbQueue)
        } catch {
            self.error = error.localizedDescription
        }
        facts.work = .none
        await refresh()
    }

    func openOwnership() async {
        guard screen.canSetOwners else { return }
        error = nil
        do {
            guard let actor = try await dbQueue.loadSignedInActor() else { throw SharingError.notAdmin }
            ownershipRows = try await dbQueue.read { db in try SharingSetup.proposal(admin: actor, db: db) }
        } catch let failure as SharingError {
            error = SharingCopy.error(failure)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The ownership sheet's Save: refused before the backup; the sheet shows any error itself.
    func saveOwners(_ rows: [SharingSetup.Row]) async throws {
        facts.work = .savingOwners
        defer { facts.work = .none }
        try await TurnOnSteps.saveOwners(rows, dbQueue: dbQueue)
        ownershipRows = nil
        NotificationCenter.default.post(name: .sharingChanged, object: nil)
        facts.work = .none
        await refresh()
    }

    /// The person's Start upload: the blockers checked again first; then the keys, the upload's start and the real
    /// sync. Nothing else ever starts it.
    func startUpload() async {
        await refresh()
        guard screen.canStartUpload, !SnapshotMode.isActive else { return }
        error = nil
        facts.work = .starting
        defer { facts.work = .none }
        do {
            let recordName = try await CloudKitAccountName.current()
            try await TurnOnSteps.beginUpload(dbQueue, cloudKitUserRecordName: recordName)
            await environment.realSync.startIfAllowed()
        } catch let failure as SyncTurnOn.TurnOnError {
            error = failure.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
        facts.work = .none
        await refresh()
    }
}

/// This Mac's iCloud user (`CloudKitAccountStatus.userRecordName`), as the sheet needs it.
enum CloudKitAccountName {
    struct Unavailable: LocalizedError {
        var errorDescription: String? { SyncTurnOn.text(.noICloudAccount) }
    }

    static func current() async throws -> String {
        do {
            return try await CloudKitAccountStatus.userRecordName()
        } catch {
            throw Unavailable()
        }
    }
}

/// The sheet around a live model.
struct TurnOnSyncSheet: View {
    @ObservedObject var model: TurnOnSyncModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TurnOnSyncSheetContent(screen: model.screen, error: model.error,
                               onBackUp: { Task { await model.backUp() } },
                               onSetOwners: { Task { await model.openOwnership() } },
                               onStartUpload: { Task { await model.startUpload() } },
                               onCheckAgain: { Task { await model.refresh() } },
                               onClose: { dismiss() })
            .task { await model.refresh() }
            .sheet(item: Binding(get: { model.ownershipRows.map(OwnershipRows.init) }, set: { if $0 == nil { model.ownershipRows = nil } })) { rows in
                OwnershipSheet(rows: rows.rows, adminName: model.adminName, onSave: { try await model.saveOwners($0) })
            }
    }

    private struct OwnershipRows: Identifiable {
        let rows: [SharingSetup.Row]
        var id: Int { 0 }
    }
}

/// The sheet from values (snapshot routes pass their own).
struct TurnOnSyncSheetContent: View {
    let screen: SyncTurnOnFlow.Screen
    var error: String?
    let onBackUp: () -> Void
    let onSetOwners: () -> Void
    let onStartUpload: () -> Void
    var onCheckAgain: () -> Void = {}
    let onClose: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        SheetScaffold(title: SyncTurnOnFlow.sheetTitle, subtitle: SyncTurnOnFlow.sheetNote, error: error, width: SheetMetrics.listWidth,
                      cancelTitle: SyncTurnOnFlow.closeButton, onCancel: onClose) {
            VStack(alignment: .leading, spacing: SheetMetrics.spacing) {
                if !screen.blockerLines.isEmpty {
                    InlineBanner(.warning) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(SyncTurnOnFlow.blockersTitle).fontWeight(.semibold)
                            ForEach(screen.blockerLines, id: \.self) { line in
                                Text("• " + line).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                step(1, SyncTurnOnFlow.backUpTitle, state: screen.backUp, line: screen.backupLine, tone: .neutral) {
                    if let title = screen.backUpButton {
                        Button(title, action: onBackUp).disabled(!screen.canBackUp)
                    }
                }
                Divider()
                step(2, SyncTurnOnFlow.ownershipTitle, state: screen.ownership, line: screen.ownershipLine, tone: .neutral) {
                    if screen.ownership != .done {
                        Button(SyncTurnOnFlow.setOwners, action: onSetOwners).disabled(!screen.canSetOwners)
                    }
                }
                Divider()
                step(3, SyncTurnOnFlow.uploadTitle, state: screen.upload, line: screen.uploadLine, tone: screen.uploadTone) {
                    if screen.showsCheckAgain {
                        Button(SyncTurnOnFlow.checkAgain, action: onCheckAgain)
                    }
                    if screen.showsStartUpload {
                        Button(SyncTurnOnFlow.startUpload, action: onStartUpload)
                            .buttonStyle(.borderedProminent)
                            .disabled(!screen.canStartUpload)
                    }
                }
                if let fraction = screen.fraction {
                    ProgressView(value: fraction)
                        .padding(.leading, 32)
                    Text(SyncTurnOnFlow.closingNote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 32)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func step(_ number: Int, _ title: String, state: SyncTurnOnFlow.StepState, line: String?, tone: SyncTurnOnFlow.Tone,
                      @ViewBuilder button: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            badge(number, state: state)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(state == .waiting ? .secondary : .primary)
                if let line {
                    Text(line.figuresUnbroken)
                        .font(.callout)
                        .foregroundStyle(tone == .amber ? theme.pending : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            button()
        }
        .accessibilityElement(children: .contain)
    }

    private func badge(_ number: Int, state: SyncTurnOnFlow.StepState) -> some View {
        ZStack {
            Circle()
                .fill(state == .done ? theme.income : (state == .current ? Color.accentColor : Color.secondary.opacity(0.25)))
            if state == .done {
                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
            } else {
                Text("\(number)").font(.caption.weight(.semibold)).foregroundStyle(state == .current ? .white : .secondary)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}
