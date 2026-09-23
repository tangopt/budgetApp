// Sources/SeedCategoryGroups/main.swift
//
// One-time seed: creates a handful of obvious category groups (Car, Subscriptions,
// Mobile Phones) and assigns the matching categories to them. A starting point, not a
// fixed taxonomy — edit or add more from the Categories screen.

import Foundation
import BudgetCore
import GRDB

let groupedCategories: [String: [String]] = [
    "Car": [
        "Car Parking Permit", "Car Payments", "Car Tax", "Car MOT", "Car Insurance",
        "Car Service", "Car Subscriptions", "Car Fines", "Car Maintenance/Accessories",
        "Car Parking", "Car Tolls", "Car Charge", "Car Gas"
    ],
    "Subscriptions": [
        "Apple iCloud / Subscriptions", "Microsoft 365", "Apple Arcade", "NOW",
        "Apple One", "Netflix", "Spotify", "Disney+", "Amazon Prime", "PlayStation Plus / Games"
    ],
    "Mobile Phones": ["Mobile Patricia", "Mobile Pablo"]
]

let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Budget", isDirectory: true)
let dbPath = appSupport.appendingPathComponent("budget.sqlite").path
print("Database: \(dbPath)")

let manager = try DatabaseManager(path: dbPath)
try manager.migrate()

try manager.dbQueue.write { db in
    for (groupName, categoryNames) in groupedCategories {
        let group: CategoryGroup
        if let existing = try CategoryGroup.filter(Column("name") == groupName).fetchOne(db) {
            group = existing
        } else {
            var newGroup = CategoryGroup(name: groupName)
            try newGroup.insert(db)
            group = newGroup
        }
        var assigned = 0
        for categoryName in categoryNames {
            guard var category = try Category.filter(Column("name") == categoryName).fetchOne(db) else {
                print("  ! no category found named '\(categoryName)', skipping")
                continue
            }
            category.groupId = group.id
            try category.update(db)
            assigned += 1
        }
        print("Group '\(groupName)': assigned \(assigned)/\(categoryNames.count) categories.")
    }
}
print("Done.")
