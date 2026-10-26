import CloudKit
import Foundation

/// Where the scene delegate hands the household invitation (`userDidAcceptCloudKitShareWith`, or the launch options of
/// a cold start from the link) to the sync controller, which may not exist yet: the invitation waits here until it
/// does.
@MainActor
final class PhoneShareInbox {
    static let shared = PhoneShareInbox()

    private var pending: [CKShare.Metadata] = []
    /// Set by `PhoneSyncController`; setting it hands over what arrived before.
    var handler: ((CKShare.Metadata) -> Void)? {
        didSet {
            guard let handler else { return }
            let waiting = pending
            pending = []
            waiting.forEach(handler)
        }
    }

    func receive(_ metadata: CKShare.Metadata) {
        if let handler {
            handler(metadata)
        } else {
            pending.append(metadata)
        }
    }
}
