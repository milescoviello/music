import Foundation

/// The shelves Home can show — Plexamp's hubs, as far as Navidrome can fill them.
enum HomeHub: String, Codable, CaseIterable, Identifiable, Sendable {
    case madeForYou
    case recentPlays
    case stations
    case recentlyPlayed
    case onThisDay
    case recentlyAdded
    case newReleases
    case shows
    case favourites
    case mostPlayed
    case mostPlayedThisMonth
    case moreInGenre
    case bestOfLastYear
    case notPlayedLately
    case forgottenFavourites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .madeForYou: return "Made for You"
        case .recentPlays: return "Recent Plays"
        case .stations: return "Stations"
        case .recentlyPlayed: return "Recently Played"
        case .onThisDay: return "On This Day"
        case .recentlyAdded: return "Recently Added"
        case .newReleases: return "New Releases"
        case .shows: return "Shows Near You"
        case .favourites: return "Favourites"
        case .mostPlayed: return "Most Played"
        case .mostPlayedThisMonth: return "Most Played This Month"
        case .moreInGenre: return "More in a Genre"
        case .bestOfLastYear: return "Best of Last Year"
        case .notPlayedLately: return "Haven't Played Lately"
        case .forgottenFavourites: return "Forgotten Favourites"
        }
    }
}

/// Something laid out by hand: Home's shelves, the Library page's rows.
protocol LayoutItem: RawRepresentable, CaseIterable, Codable, Hashable, Identifiable, Sendable
    where RawValue == String, AllCases == [Self] {
    /// Out of the way until asked for, before anything has been chosen.
    static var hiddenByDefault: Set<Self> { get }
}

extension HomeHub: LayoutItem {
    static var hiddenByDefault: Set<HomeHub> { [] }
}

/// Home's shelves: Plexamp's home editor, stored.
typealias HomeLayout = ItemLayout<HomeHub>

/// Which items show, in what order, stored.
struct ItemLayout<Item: LayoutItem>: Codable, Equatable, Sendable {
    private(set) var order: [Item]
    private(set) var hidden: Set<Item>

    static var `default`: ItemLayout { ItemLayout(order: Item.allCases, hidden: Item.hiddenByDefault) }

    var visible: [Item] { order.filter { !hidden.contains($0) } }
    var hiddenInOrder: [Item] { order.filter { hidden.contains($0) } }

    func isVisible(_ item: Item) -> Bool { !hidden.contains(item) }

    mutating func setVisible(_ visible: Bool, _ item: Item) {
        if visible { hidden.remove(item) } else { hidden.insert(item) }
    }

    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        // `Array.move(fromOffsets:toOffset:)` is SwiftUI's; this is the same, in Foundation.
        let moving = source.map { order[$0] }
        var rest = order.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: max(0, min(insertAt, rest.count)))
        order = rest
    }

    /// A stored layout, repaired: items this build no longer has are dropped, and ones it
    /// added since are put where the default order has them, shown or not as it has them,
    /// rather than lost.
    static func restored(from data: Data?) -> ItemLayout {
        guard let data,
              let stored = try? JSONDecoder().decode(StoredLayout.self, from: data)
        else { return .default }

        // A row retired since (Charts, folded into Stats) is dropped rather than kept as a way in
        // the page no longer offers.
        let offered = Set(Item.allCases)
        var order = stored.order.compactMap(Item.init(rawValue:)).filter { offered.contains($0) }
        var seen = Set<Item>()
        order = order.filter { seen.insert($0).inserted }

        var hidden = Set(stored.hidden.compactMap(Item.init(rawValue:)))
        for (index, item) in Item.allCases.enumerated() where !seen.contains(item) {
            order.insert(item, at: min(index, order.count))
            if Item.hiddenByDefault.contains(item) { hidden.insert(item) }
        }
        return ItemLayout(order: order, hidden: hidden)
    }

    var encoded: Data? {
        try? JSONEncoder().encode(StoredLayout(order: order.map(\.rawValue), hidden: hidden.map(\.rawValue).sorted()))
    }

    /// Raw strings on disk, so an item removed in a later build cannot make the whole
    /// layout fail to decode.
    private struct StoredLayout: Codable {
        let order: [String]
        let hidden: [String]
    }
}
