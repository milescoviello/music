import Foundation

/// The shelves Home can show — Plexamp's hubs, as far as Navidrome can fill them.
enum HomeHub: String, Codable, CaseIterable, Identifiable, Sendable {
    case madeForYou
    case stations
    case recentlyPlayed
    case onThisDay
    case recentlyAdded
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
        case .stations: return "Stations"
        case .recentlyPlayed: return "Recently Played"
        case .onThisDay: return "On This Day"
        case .recentlyAdded: return "Recently Added"
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

/// Which shelves Home shows, in what order: Plexamp's home editor, stored.
struct HomeLayout: Codable, Equatable, Sendable {
    private(set) var order: [HomeHub]
    private(set) var hidden: Set<HomeHub>

    static let `default` = HomeLayout(order: HomeHub.allCases, hidden: [])

    var visible: [HomeHub] { order.filter { !hidden.contains($0) } }

    func isVisible(_ hub: HomeHub) -> Bool { !hidden.contains(hub) }

    mutating func setVisible(_ visible: Bool, _ hub: HomeHub) {
        if visible { hidden.remove(hub) } else { hidden.insert(hub) }
    }

    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        // `Array.move(fromOffsets:toOffset:)` is SwiftUI's; this is the same, in Foundation.
        let moving = source.map { order[$0] }
        var rest = order.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: max(0, min(insertAt, rest.count)))
        order = rest
    }

    /// A stored layout, repaired: hubs this build no longer has are dropped, and ones it
    /// added since are put where the default order has them rather than lost.
    static func restored(from data: Data?) -> HomeLayout {
        guard let data,
              let stored = try? JSONDecoder().decode(StoredLayout.self, from: data)
        else { return .default }

        var order = stored.order.compactMap(HomeHub.init(rawValue:))
        var seen = Set<HomeHub>()
        order = order.filter { seen.insert($0).inserted }

        for (index, hub) in HomeHub.allCases.enumerated() where !seen.contains(hub) {
            order.insert(hub, at: min(index, order.count))
        }
        let hidden = Set(stored.hidden.compactMap(HomeHub.init(rawValue:)))
        return HomeLayout(order: order, hidden: hidden)
    }

    var encoded: Data? {
        try? JSONEncoder().encode(StoredLayout(order: order.map(\.rawValue), hidden: hidden.map(\.rawValue).sorted()))
    }

    /// Raw strings on disk, so a hub removed in a later build cannot make the whole
    /// layout fail to decode.
    private struct StoredLayout: Codable {
        let order: [String]
        let hidden: [String]
    }
}
