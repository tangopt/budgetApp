// Sources/SeedCategoryGroups/main.swift
//
// One-time seed: creates a handful of obvious category groups (Car, Subscriptions,
// Mobile Phones) and assigns the matching categories to them. A starting point, not a
// fixed taxonomy — edit or add more from the Categories screen.
//
// Usage: SeedCategoryGroups [--names <names.json>]
//   --names  a JSON object mapping the default category names below ("Mobile 1") to the
//            database's own, when they differ (a personal data file kept outside the repository).

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
    "Mobile Phones": ["Mobile 1", "Mobile 2"]
]

var categoryNames: [String: String] = [:]
let arguments = Array(CommandLine.arguments.dropFirst())
if let index = arguments.firstIndex(of: "--names") {
    guard index + 1 < arguments.count,
          let names = try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[index + 1]))) else {
        print("--names needs a JSON object file: {\"Mobile 1\": \"<your category>\", …}")
        exit(2)
    }
    categoryNames = names
}

let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Budget", isDirectory: true)
let dbPath = appSupport.appendingPathComponent("budget.sqlite").path
print("Database: \(dbPath)")

let manager = try DatabaseManager(path: dbPath)
try manager.migrate()

try manager.dbQueue.write { db in
    for (groupName, categoryNamesInGroup) in groupedCategories {
        let group: CategoryGroup
        if let existing = try CategoryGroup.filter(Column("name") == groupName).fetchOne(db) {
            group = existing
        } else {
            var newGroup = CategoryGroup(name: groupName)
            try newGroup.insert(db)
            group = newGroup
        }
        var assigned = 0
        for defaultName in categoryNamesInGroup {
            let categoryName = categoryNames[defaultName] ?? defaultName
            guard var category = try Category.filter(Column("name") == categoryName).fetchOne(db) else {
                print("  ! no category found named '\(categoryName)', skipping")
                continue
            }
            category.groupId = group.id
            try category.update(db)
            assigned += 1
        }
        print("Group '\(groupName)': assigned \(assigned)/\(categoryNamesInGroup.count) categories.")
    }
}
print("Done.")
