import Foundation
import Observation

/// How the playlists are listed: the pinned ones first, in the order he put them, then the
/// rest -- in an order of his own, or by name, by when they last changed, by size.
///
/// Kept on this device, not on the server: Subsonic has no order or pin for playlists, and
/// desktop Feishin keeps its own. Ids, not names, so renaming a playlist keeps its place.
/// There is no cap on pins: four was the ask ("my main 4"), and a cap would only be a
/// number to run into.
@MainActor
@Observable
final class PlaylistArrangement {
    enum Sort: String, CaseIterable, Codable, Identifiable, Sendable {
        case custom
        case name
        case recentlyChanged
        case mostSongs
        case longest

        var id: String { rawValue }

        var title: String {
            switch self {
            case .custom: return "My Order"
            case .name: return "Name"
            case .recentlyChanged: return "Recently Changed"
            case .mostSongs: return "Most Songs"
            case .longest: return "Longest"
            }
        }
    }

    private enum Key {
        static let pinned = "playlists.pinned"
        static let custom = "playlists.custom"
        static let sort = "playlists.sort"
        static let picker = "playlists.picker"
    }

    private(set) var pinned: [String]
    private(set) var custom: [String]
    /// Add to Playlist's own order, apart from the Playlists tab's: the ones he adds to
    /// most, at the top. Empty until he first moves one there.
    private(set) var picker: [String]
    var sort: Sort {
        didSet { defaults.set(sort.rawValue, forKey: Key.sort) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pinned = defaults.stringArray(forKey: Key.pinned) ?? []
        custom = defaults.stringArray(forKey: Key.custom) ?? []
        picker = defaults.stringArray(forKey: Key.picker) ?? []
        sort = (defaults.string(forKey: Key.sort)).flatMap(Sort.init(rawValue:)) ?? .name
    }

    // MARK: - Reading

    func isPinned(_ playlist: Playlist) -> Bool {
        pinned.contains(playlist.id)
    }

    func arranged(_ playlists: [Playlist]) -> (pinned: [Playlist], rest: [Playlist]) {
        Self.arrange(playlists, pinned: pinned, custom: custom, sort: sort)
    }

    /// The playlists as Add to Playlist lists them.
    func forPicker(_ playlists: [Playlist]) -> [Playlist] {
        Self.pickerOrder(playlists, picker: picker, pinned: pinned, custom: custom, sort: sort)
    }

    // MARK: - Changing

    /// Pinned at the bottom of the pinned ones: the newest pin is the last to be chosen.
    func togglePin(_ playlist: Playlist) {
        if let index = pinned.firstIndex(of: playlist.id) {
            pinned.remove(at: index)
        } else {
            pinned.append(playlist.id)
        }
        defaults.set(pinned, forKey: Key.pinned)
    }

    /// `shown` is the pinned list as it is on screen; offsets are SwiftUI's `onMove`.
    func movePinned(from source: IndexSet, to destination: Int, shown: [Playlist]) {
        pinned = Self.moved(shown.map(\.id), from: source, to: destination)
        defaults.set(pinned, forKey: Key.pinned)
    }

    /// Moving one by hand is choosing an order of his own: the list as it is on screen,
    /// with the move, becomes My Order.
    func moveRest(from source: IndexSet, to destination: Int, shown: [Playlist]) {
        custom = Self.moved(shown.map(\.id), from: source, to: destination)
        defaults.set(custom, forKey: Key.custom)
        if sort != .custom { sort = .custom }
    }

    /// `shown` is the picker's list as it is on screen; offsets are SwiftUI's `onMove`.
    func movePicker(from source: IndexSet, to destination: Int, shown: [Playlist]) {
        picker = Self.moved(shown.map(\.id), from: source, to: destination)
        defaults.set(picker, forKey: Key.picker)
    }

    // MARK: - The rules, Foundation-only so they are tested

    /// Until he orders the picker it follows the Playlists tab, pinned ones first, so his
    /// main ones are already at the top. After that his order, then any playlist made
    /// since, in the tab's order, at the end.
    static func pickerOrder(
        _ playlists: [Playlist], picker: [String], pinned: [String], custom: [String], sort: Sort
    ) -> [Playlist] {
        let tab = arrange(playlists, pinned: pinned, custom: custom, sort: sort)
        let base = tab.pinned + tab.rest
        guard !picker.isEmpty else { return base }
        let place = Dictionary(picker.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let known = base.filter { place[$0.id] != nil }.sorted { place[$0.id]! < place[$1.id]! }
        return known + base.filter { place[$0.id] == nil }
    }

    static func arrange(
        _ playlists: [Playlist], pinned: [String], custom: [String], sort: Sort
    ) -> (pinned: [Playlist], rest: [Playlist]) {
        let byID = Dictionary(playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pinnedShown = pinned.compactMap { byID[$0] }
        let pinnedSet = Set(pinnedShown.map(\.id))
        let rest = playlists.filter { !pinnedSet.contains($0.id) }
        return (pinnedShown, ordered(rest, custom: custom, sort: sort))
    }

    private static func ordered(_ playlists: [Playlist], custom: [String], sort: Sort) -> [Playlist] {
        let byName: (Playlist, Playlist) -> Bool = {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        switch sort {
        case .name:
            return playlists.sorted(by: byName)
        case .custom:
            // His order, then any playlist made since, by name, at the end.
            let place = Dictionary(custom.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            let known = playlists.filter { place[$0.id] != nil }.sorted { place[$0.id]! < place[$1.id]! }
            let new = playlists.filter { place[$0.id] == nil }.sorted(by: byName)
            return known + new
        case .recentlyChanged:
            // ISO 8601 in one format and zone, so the strings sort as the dates do.
            return playlists.sorted { a, b in
                (a.changed ?? "") != (b.changed ?? "") ? (a.changed ?? "") > (b.changed ?? "") : byName(a, b)
            }
        case .mostSongs:
            return playlists.sorted { a, b in
                (a.songCount ?? 0) != (b.songCount ?? 0) ? (a.songCount ?? 0) > (b.songCount ?? 0) : byName(a, b)
            }
        case .longest:
            return playlists.sorted { a, b in
                (a.duration ?? 0) != (b.duration ?? 0) ? (a.duration ?? 0) > (b.duration ?? 0) : byName(a, b)
            }
        }
    }

    /// `Array.move(fromOffsets:toOffset:)`, which is SwiftUI's, in Foundation.
    static func moved(_ ids: [String], from source: IndexSet, to destination: Int) -> [String] {
        let moving = source.map { ids[$0] }
        var rest = ids.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: max(0, min(insertAt, rest.count)))
        return rest
    }
}
