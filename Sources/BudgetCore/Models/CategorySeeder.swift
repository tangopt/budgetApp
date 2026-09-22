import GRDB

public enum CategorySeeder {
    public static let expenseNames: [String] = [
        "Rent", "Internet", "Gas/Electricity", "Mobile Patricia", "Mobile Pablo",
        "Apple iCloud / Subscriptions", "Microsoft 365", "Apple Arcade", "NOW",
        "Apple One", "Netflix", "Spotify", "Disney+", "Council Tax",
        "HP Instant Ink", "TV License", "Amazon Prime", "PlayStation Plus / Games",
        "Thames Water",
        "Car Parking Permit", "Car Payments", "Car Tax", "Car MOT", "Car Insurance",
        "Car Service", "Car Subscriptions", "Car Fines", "Car Maintenance/Accessories",
        "Car Parking", "Car Tolls", "Car Charge", "Car Gas",
        "Commute / Public Transport", "Meals/Drinks", "Delivery", "Eating Out",
        "Holidays / Travel / Events", "Sport", "Groceries",
        "House Decor / Move Expenses", "Optician",
        "Confirmed other expenses", "Confirmed other SIGNIFICANT expenses"
    ]

    public static let transferNames: [String] = [
        "Business Expenses (credit) / AMEX Travel (debit)",
        "Investments (Stocks + Crypto)", "Trading tools & training",
        "Transfer: Santander Patricia", "Transfer: Lloyds Joint",
        "Transfer: Lloyds International EUR", "Transfer: Lloyds Investment ISA",
        "Transfer: BBVA Portugal", "Accountant", "UK Taxes"
    ]

    public static let incomeNames: [String] = ["Income", "Bonus", "Other income/refunds"]

    public static func seedDefaults(_ db: Database) throws {
        for name in expenseNames {
            var category = Category(name: name, type: .expense)
            if try Category.filter(Column("name") == name).fetchCount(db) == 0 {
                try category.insert(db)
            }
        }
        for name in transferNames {
            var category = Category(name: name, type: .transfer)
            if try Category.filter(Column("name") == name).fetchCount(db) == 0 {
                try category.insert(db)
            }
        }
        for name in incomeNames {
            var category = Category(name: name, type: .income)
            if try Category.filter(Column("name") == name).fetchCount(db) == 0 {
                try category.insert(db)
            }
        }
    }
}
