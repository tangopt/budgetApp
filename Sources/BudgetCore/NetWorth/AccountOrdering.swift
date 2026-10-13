import Foundation
import GRDB

/// The one order accounts are listed in everywhere (Accounts screen, Budget panel and grid,
/// pickers, Dashboard): accounts with a `sortOrder` first, ascending; the rest after them
/// alphabetically (`Account.displayNameOrder`). Drag and drop renumbers via `move`.
public enum AccountOrdering {
    public static func sorted(_ accounts: [Account]) -> [Account] {
        accounts.sorted(by: areInOrder)
    }

    public static func areInOrder(_ lhs: Account, _ rhs: Account) -> Bool {
        switch (lhs.sortOrder, rhs.sortOrder) {
        case let (l?, r?) where l != r: return l < r
        case (_?, nil): return true
        case (nil, _?): return false
        default: return Account.displayNameOrder(lhs, rhs)
        }
    }

    /// Applies a drag in a displayed list of accounts: `ids` is that list in its displayed
    /// order (all accounts, or a subset such as one kind's section), `fromOffsets`/`toOffset`
    /// are SwiftUI's move offsets into it. The subset is reordered within the positions it
    /// already holds in the full order, so other accounts stay put; then every account is
    /// renumbered 0…n-1 (the first move thereby assigns an order to all of them, in the
    /// order they were displayed). Unknown ids are ignored.
    public static func move(db: Database, ids: [Int64], fromOffsets: IndexSet, toOffset: Int) throws {
        let all = sorted(try Account.fetchAll(db))
        let known = Set(all.compactMap(\.id))
        let moved = moving(ids, fromOffsets: fromOffsets, toOffset: toOffset).filter(known.contains)
        let subset = Set(moved)
        var replacements = moved.makeIterator()
        let newOrder: [Int64] = all.compactMap(\.id).map { id in
            subset.contains(id) ? replacements.next()! : id
        }
        for (index, id) in newOrder.enumerated() {
            try db.execute(sql: "UPDATE account SET sortOrder = ? WHERE id = ?", arguments: [index, id])
        }
    }

    /// `MutableCollection.move(fromOffsets:toOffset:)` (SwiftUI's) without SwiftUI: the
    /// items at `fromOffsets` end up, in their order, before the item that was at `toOffset`.
    static func moving<T>(_ items: [T], fromOffsets: IndexSet, toOffset: Int) -> [T] {
        let valid = fromOffsets.filter(items.indices.contains)
        let movingItems = valid.map { items[$0] }
        let before = items.indices.filter { $0 < toOffset && !valid.contains($0) }.map { items[$0] }
        let after = items.indices.filter { $0 >= toOffset && !valid.contains($0) }.map { items[$0] }
        return before + movingItems + after
    }

    /// Where a new account goes: nil (alphabetical among the unordered) until any account has
    /// an order, then after the last one.
    static func orderForNewAccount(db: Database) throws -> Int? {
        try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) FROM account").map { $0 + 1 }
    }
}
