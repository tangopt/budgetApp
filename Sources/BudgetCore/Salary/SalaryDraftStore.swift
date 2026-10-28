import Foundation

/// What the salary simulator held when it was last edited: both salaries, kept on this device only.
public struct SalaryDraft: Codable, Equatable, Sendable {
    public var current: SalaryInputs
    public var offer: SalaryInputs
    /// The person the draft was made for, when it was known (a device several people sign in to); nil when unknown.
    public var personId: Int64?

    public init(current: SalaryInputs, offer: SalaryInputs, personId: Int64? = nil) {
        self.current = current
        self.offer = offer
        self.personId = personId
    }
}

/// The simulator's draft in this device's `UserDefaults`. Never synced, never in the database; cleared on sign-out,
/// leaving the household and demo data (`SalaryComparisonViewModel.forget`).
public struct SalaryDraftStore: @unchecked Sendable {
    public static let defaultKey = "salarySimulatorDraft.v1"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = SalaryDraftStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    /// The saved draft; nil when there is none or it can't be read.
    public func load() -> SalaryDraft? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SalaryDraft.self, from: data)
    }

    public func save(_ draft: SalaryDraft) {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        defaults.set(data, forKey: key)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}
