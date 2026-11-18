import Foundation

/// What the phone and the watch say to each other over WatchConnectivity, compiled into
/// both. The phone's state goes as the application context, so the watch always finds the
/// latest when it next looks, whatever it missed; the watch's commands go as messages,
/// which wake the phone's app; songs the watch keeps go as file transfers, each with its
/// `Track` as metadata.
enum WatchLink {
    /// What the watch shows of the phone: the song playing and what can be played.
    struct State: Codable, Equatable, Sendable {
        var title: String?
        var artist: String?
        var album: String?
        var isPlaying = false
        /// Where the song was at `anchor`, so the watch's progress runs on its own.
        var elapsed: Double = 0
        var duration: Double = 0
        var anchor = Date.distantPast
        var rating = 0
        var isFavourite = false
        var pinned: [Item] = []
        var mixes: [Item] = []
        var playlists: [Item] = []
    }

    /// A playlist or a mix: something to play on the phone, or to keep on the watch.
    struct Item: Codable, Equatable, Hashable, Sendable, Identifiable {
        enum Kind: String, Codable, Sendable {
            case playlist, mix
        }

        var kind: Kind
        var id: String
        var name: String
        var detail: String?
    }

    /// A song sent to the watch to keep. Its file comes with it.
    struct Track: Codable, Equatable, Hashable, Sendable, Identifiable {
        var id: String
        var title: String
        var artist: String?
        var album: String?
        var duration: Double
        /// What it was kept for (an `Item`'s id and name), its place there and how many
        /// songs that holds, so the watch can show how far a download has got.
        var collection: String
        var collectionName: String
        var index: Int
        var total: Int
    }

    enum Command: Codable, Equatable, Sendable {
        case toggle, next, previous
        case favourite
        case rate(Int)
        /// Play it on the phone.
        case play(Item)
        /// Send its songs to the watch to keep.
        case keep(Item)
        /// Stop sending a collection that is still on its way.
        case stopKeeping(String)
    }

    static let stateKey = "state"
    static let coverKey = "cover"
    static let commandKey = "command"
    static let trackKey = "track"

    static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: Any?) -> T? {
        guard let data = value as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
