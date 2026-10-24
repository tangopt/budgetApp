import CloudKit

/// The iCloud account check both apps make before syncing (sync spec §5.6): a wrapper over
/// `CKContainer.accountStatus` that reports only what the apps act on.
public enum CloudKitAccountStatus {
    public enum Status: Equatable, Sendable {
        case available
        case noAccount
        case restricted
        /// CloudKit couldn't tell, or the account is signed in but temporarily unusable: try again later.
        case couldNotDetermine
    }

    /// The account status for `container`; any error reads as `couldNotDetermine`.
    public static func current(container: String = CloudKitTransport.containerIdentifier) async -> Status {
        do {
            return status(for: try await CKContainer(identifier: container).accountStatus())
        } catch {
            return .couldNotDetermine
        }
    }

    static func status(for status: CKAccountStatus) -> Status {
        switch status {
        case .available: return .available
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .couldNotDetermine, .temporarilyUnavailable: return .couldNotDetermine
        @unknown default: return .couldNotDetermine
        }
    }
}
