import Foundation

/// One pickable category icon: an SF Symbol plus words the icon picker's search matches.
public struct CategoryIcon: Equatable, Hashable, Sendable, Identifiable {
    public let symbol: String
    public let keywords: String

    public var id: String { symbol }

    public init(_ symbol: String, _ keywords: String) {
        self.symbol = symbol
        self.keywords = keywords
    }

    func matches(_ query: String) -> Bool {
        symbol.localizedCaseInsensitiveContains(query)
            || symbol.replacingOccurrences(of: ".", with: " ").localizedCaseInsensitiveContains(query)
            || keywords.localizedCaseInsensitiveContains(query)
    }
}

/// A themed block of the icon picker's grid.
public struct CategoryIconTheme: Equatable, Sendable, Identifiable {
    public let title: String
    public let icons: [CategoryIcon]

    public var id: String { title }

    public init(title: String, icons: [CategoryIcon]) {
        self.title = title
        self.icons = icons
    }
}

/// The curated, finance-relevant SF Symbols a category can use (spec: category icons),
/// grouped by theme. Each symbol appears once; a test checks every one exists.
public enum CategoryIcons {
    public static let themes: [CategoryIconTheme] = [
        CategoryIconTheme(title: "Home & bills", icons: [
            CategoryIcon("house.fill", "home rent mortgage housing"),
            CategoryIcon("building.2.fill", "council tax flat apartment"),
            CategoryIcon("bolt.fill", "electricity energy power"),
            CategoryIcon("flame.fill", "gas heating energy"),
            CategoryIcon("drop.fill", "water utilities"),
            CategoryIcon("wifi", "internet broadband"),
            CategoryIcon("phone.fill", "phone landline"),
            CategoryIcon("iphone", "mobile phone contract"),
            CategoryIcon("tv.fill", "tv licence streaming television"),
            CategoryIcon("sofa.fill", "furniture furnishings"),
            CategoryIcon("hammer.fill", "repairs diy"),
            CategoryIcon("wrench.and.screwdriver.fill", "maintenance repairs tools"),
            CategoryIcon("lightbulb.fill", "lighting household"),
            CategoryIcon("leaf.fill", "garden plants"),
            CategoryIcon("trash.fill", "bins waste cleaning"),
        ]),
        CategoryIconTheme(title: "Food & drink", icons: [
            CategoryIcon("cart.fill", "groceries supermarket shopping food"),
            CategoryIcon("basket.fill", "groceries market"),
            CategoryIcon("fork.knife", "restaurants eating out dining meals"),
            CategoryIcon("cup.and.saucer.fill", "coffee tea cafe"),
            CategoryIcon("takeoutbag.and.cup.and.straw.fill", "takeaway fast food delivery"),
            CategoryIcon("wineglass.fill", "wine alcohol drinks bar pub"),
            CategoryIcon("mug.fill", "coffee drinks"),
            CategoryIcon("birthday.cake.fill", "cake bakery celebration birthday"),
            CategoryIcon("carrot.fill", "vegetables groceries"),
        ]),
        CategoryIconTheme(title: "Transport & car", icons: [
            CategoryIcon("car.fill", "car vehicle motoring"),
            CategoryIcon("fuelpump.fill", "fuel petrol diesel gas"),
            CategoryIcon("bus.fill", "bus public transport"),
            CategoryIcon("tram.fill", "tram metro underground tube"),
            CategoryIcon("train.side.front.car", "train rail commute"),
            CategoryIcon("bicycle", "bike cycling"),
            CategoryIcon("scooter", "scooter"),
            CategoryIcon("parkingsign", "parking"),
            CategoryIcon("steeringwheel", "driving car insurance lessons"),
            CategoryIcon("ferry.fill", "ferry boat"),
            CategoryIcon("airplane", "flights travel holiday"),
        ]),
        CategoryIconTheme(title: "Shopping", icons: [
            CategoryIcon("bag.fill", "shopping retail"),
            CategoryIcon("handbag.fill", "accessories shopping"),
            CategoryIcon("tshirt.fill", "clothes clothing fashion"),
            CategoryIcon("shoe.fill", "shoes footwear"),
            CategoryIcon("gift.fill", "gifts presents christmas"),
            CategoryIcon("laptopcomputer", "electronics computer tech"),
            CategoryIcon("gamecontroller.fill", "games gaming"),
            CategoryIcon("book.fill", "books reading"),
            CategoryIcon("shippingbox.fill", "online orders delivery amazon"),
        ]),
        CategoryIconTheme(title: "Leisure & travel", icons: [
            CategoryIcon("film.fill", "cinema movies"),
            CategoryIcon("ticket.fill", "tickets events concerts"),
            CategoryIcon("music.note", "music spotify concerts"),
            CategoryIcon("headphones", "audio podcasts music"),
            CategoryIcon("figure.run", "running sport fitness"),
            CategoryIcon("dumbbell.fill", "gym fitness"),
            CategoryIcon("sportscourt.fill", "sport tennis football"),
            CategoryIcon("suitcase.fill", "travel holiday luggage"),
            CategoryIcon("beach.umbrella.fill", "holiday beach vacation"),
            CategoryIcon("tent.fill", "camping outdoors"),
            CategoryIcon("camera.fill", "photography"),
            CategoryIcon("paintpalette.fill", "hobbies art crafts"),
            CategoryIcon("theatermasks.fill", "theatre entertainment"),
            CategoryIcon("party.popper.fill", "party celebration events"),
            CategoryIcon("globe.europe.africa.fill", "travel abroad world"),
        ]),
        CategoryIconTheme(title: "Health", icons: [
            CategoryIcon("heart.fill", "health wellbeing"),
            CategoryIcon("cross.case.fill", "medical first aid"),
            CategoryIcon("pills.fill", "pharmacy medicine prescriptions"),
            CategoryIcon("stethoscope", "doctor gp medical"),
            CategoryIcon("bandage.fill", "injury first aid"),
            CategoryIcon("eyeglasses", "optician glasses eyes"),
            CategoryIcon("mouth.fill", "dentist dental teeth"),
            CategoryIcon("scissors", "haircut hairdresser barber"),
            CategoryIcon("figure.mind.and.body", "yoga therapy wellbeing"),
            CategoryIcon("sparkles", "beauty cosmetics"),
        ]),
        CategoryIconTheme(title: "Money & transfers", icons: [
            CategoryIcon("banknote.fill", "cash money"),
            CategoryIcon("sterlingsign.circle.fill", "pounds money gbp"),
            CategoryIcon("dollarsign.circle.fill", "dollars money usd"),
            CategoryIcon("eurosign.circle.fill", "euros money eur"),
            CategoryIcon("creditcard.fill", "card credit card payment"),
            CategoryIcon("building.columns.fill", "bank loan"),
            CategoryIcon("chart.line.uptrend.xyaxis", "investments stocks shares pension"),
            CategoryIcon("chart.pie.fill", "portfolio investments budget"),
            CategoryIcon("percent", "interest fees"),
            CategoryIcon("lock.fill", "savings safe"),
            CategoryIcon("umbrella.fill", "insurance protection"),
            CategoryIcon("doc.text.fill", "tax bills statements"),
            CategoryIcon("arrow.left.arrow.right", "transfer move money"),
            CategoryIcon("arrow.up.right", "expense outgoing payment"),
            CategoryIcon("arrow.down.left", "income incoming payment"),
            CategoryIcon("arrow.uturn.backward", "refunds returns"),
        ]),
        CategoryIconTheme(title: "Work & income", icons: [
            CategoryIcon("briefcase.fill", "salary work job wages"),
            CategoryIcon("building.fill", "employer office company"),
            CategoryIcon("desktopcomputer", "work freelance computer"),
            CategoryIcon("graduationcap.fill", "education school university tuition"),
            CategoryIcon("star.fill", "bonus reward"),
            CategoryIcon("clock.fill", "overtime hours"),
            CategoryIcon("signature", "contract self employed invoice"),
            CategoryIcon("person.2.fill", "family people benefits"),
            CategoryIcon("hand.raised.fill", "charity donations"),
        ]),
        CategoryIconTheme(title: "Kids & pets", icons: [
            CategoryIcon("figure.child", "family kids children"),
            CategoryIcon("stroller.fill", "baby childcare nursery"),
            CategoryIcon("teddybear.fill", "toys kids"),
            CategoryIcon("backpack.fill", "school kids"),
            CategoryIcon("balloon.fill", "kids party"),
            CategoryIcon("pawprint.fill", "pets vet"),
            CategoryIcon("dog.fill", "dog pet"),
            CategoryIcon("cat.fill", "cat pet"),
            CategoryIcon("fish.fill", "fish pet"),
            CategoryIcon("bird.fill", "bird pet"),
        ]),
        CategoryIconTheme(title: "Other", icons: [
            CategoryIcon("tag.fill", "general misc"),
            CategoryIcon("repeat", "subscriptions recurring"),
            CategoryIcon("newspaper.fill", "news subscriptions magazines"),
            CategoryIcon("envelope.fill", "post postage mail"),
            CategoryIcon("calendar", "annual yearly"),
            CategoryIcon("tray.fill", "reserve buffer"),
            CategoryIcon("archivebox.fill", "storage"),
            CategoryIcon("exclamationmark.triangle.fill", "fines penalties charges"),
            CategoryIcon("questionmark.circle.fill", "unknown misc"),
            CategoryIcon("ellipsis.circle.fill", "other misc"),
        ]),
    ]

    /// Every curated symbol, in theme order.
    public static var allSymbols: [String] { themes.flatMap { $0.icons.map(\.symbol) } }

    /// The themes filtered by `query` (trimmed, case-insensitive): a theme whose title
    /// matches keeps all its icons, otherwise only icons whose symbol or keywords match;
    /// themes left empty are dropped. A blank query returns every theme.
    public static func search(_ query: String) -> [CategoryIconTheme] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return themes }
        return themes.compactMap { theme in
            if theme.title.localizedCaseInsensitiveContains(trimmed) { return theme }
            let icons = theme.icons.filter { $0.matches(trimmed) }
            return icons.isEmpty ? nil : CategoryIconTheme(title: theme.title, icons: icons)
        }
    }
}
