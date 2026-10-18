import Foundation

/// The network the phone is on, as far as streaming is concerned.
enum NetworkKind: Sendable, Equatable {
    case wifi
    /// Cellular, a personal hotspot, or Low Data Mode — anything that costs.
    case cellular
    case offline
}

/// A streaming bitrate ceiling.
///
/// Plexamp's list, minus its 2 Mbps and 1 Mbps rungs: those are lossless-to-lossy
/// conversions at high rates that Plex can produce and Navidrome cannot. Everything
/// else maps straight onto `stream.view?format=mp3&maxBitRate=`.
enum StreamQuality: Int, Codable, CaseIterable, Identifiable, Sendable {
    case original = 0
    case kbps320 = 320
    case kbps256 = 256
    case kbps192 = 192
    case kbps160 = 160
    case kbps128 = 128
    case kbps96 = 96
    case kbps64 = 64

    var id: Int { rawValue }

    /// Nil for the stored file, unconverted.
    var maxBitRate: Int? { self == .original ? nil : rawValue }

    var label: String { self == .original ? "Maximum" : "\(rawValue) kbps" }

    /// Plexamp offers the two lowest rates on cellular only.
    static let wifiOptions: [StreamQuality] = [.original, .kbps320, .kbps256, .kbps192, .kbps160, .kbps128]
    static let cellularOptions: [StreamQuality] = wifiOptions + [.kbps96, .kbps64]
}

/// When a downloaded copy is played instead of the stream. Plexamp's three choices.
enum PreferDownloads: Int, Codable, CaseIterable, Identifiable, Sendable {
    case always = 2
    case onCellular = 1
    case never = 0

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .always: return "Always"
        case .onCellular: return "On Cellular"
        case .never: return "Never"
        }
    }
}

/// Plexamp's streaming and caching settings, and every decision that follows from them.
///
/// Foundation-only so the decisions can be tested: which variant of a track to ask for
/// on which network, whether a download beats the stream, how far ahead to cache.
///
/// Defaults are Plexamp's except in two places, both to keep what this app already did:
/// cellular streams the original rather than 128 kbps, and downloads are always
/// preferred rather than only on cellular. Downloads here are the original file unless
/// asked otherwise, so streaming over one on Wi-Fi would only ever cost.
struct StreamingPolicy: Codable, Equatable, Sendable {
    var wifiQuality: StreamQuality = .original
    var cellularQuality: StreamQuality = .original
    /// Tracks to fetch ahead of the one playing. Zero is Plexamp's "Only next track".
    var wifiCacheAhead = 15
    var cellularCacheAhead = 5
    var cacheMegabytes = 1_024
    var preferDownloads: PreferDownloads = .always

    static let cacheAheadOptions = [0, 5, 10, 15, 20, 25, 40]
    /// Plexamp's mobile list. 512 MB is its default; 1 GB here, because fifteen tracks
    /// of lossless ahead is already about half a gigabyte.
    static let cacheSizeOptions = [512, 1_024, 2_048, 4_096, 8_192, 16_384, 32_768]

    var cacheBytes: Int64 { Int64(cacheMegabytes) * 1_024 * 1_024 }

    init() {}

    /// Every field optional on the way in, so a setting added later does not reset the
    /// ones already chosen.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = StreamingPolicy()
        wifiQuality = try container.decodeIfPresent(StreamQuality.self, forKey: .wifiQuality) ?? defaults.wifiQuality
        cellularQuality = try container.decodeIfPresent(StreamQuality.self, forKey: .cellularQuality) ?? defaults.cellularQuality
        wifiCacheAhead = try container.decodeIfPresent(Int.self, forKey: .wifiCacheAhead) ?? defaults.wifiCacheAhead
        cellularCacheAhead = try container.decodeIfPresent(Int.self, forKey: .cellularCacheAhead) ?? defaults.cellularCacheAhead
        cacheMegabytes = try container.decodeIfPresent(Int.self, forKey: .cacheMegabytes) ?? defaults.cacheMegabytes
        preferDownloads = try container.decodeIfPresent(PreferDownloads.self, forKey: .preferDownloads) ?? defaults.preferDownloads
    }

    func quality(on network: NetworkKind) -> StreamQuality {
        network == .wifi ? wifiQuality : cellularQuality
    }

    /// Tracks after the current one to have on the phone before they play.
    func tracksAhead(on network: NetworkKind) -> Int {
        switch network {
        case .wifi: return max(1, wifiCacheAhead)
        case .cellular: return max(1, cellularCacheAhead)
        case .offline: return 0
        }
    }

    /// Whether a completed download should be played rather than streaming.
    ///
    /// Offline it always is, whatever the setting: "never" is a preference about which
    /// copy sounds better, and silence is not a better copy.
    func usesDownload(on network: NetworkKind) -> Bool {
        switch preferDownloads {
        case .always: return true
        case .onCellular: return network != .wifi
        case .never: return network == .offline
        }
    }

    /// What to ask the server for.
    ///
    /// The ceiling only ever lowers quality: a file already at or under it is fetched
    /// as it is, because converting a 128 kbps MP3 to "320 kbps" adds nothing but a
    /// second generation of loss. Containers iOS cannot decode are converted whatever
    /// the setting — at 320 kbps unless the ceiling is lower.
    func variant(for song: Song, on network: NetworkKind) -> StreamVariant {
        let ceiling = quality(on: network).maxBitRate

        if Self.needsTranscode(song.suffix) {
            return .mp3(kbps: min(ceiling ?? 320, 320))
        }
        guard let ceiling else { return .original }
        if let rate = song.bitRate, rate > 0, rate <= ceiling { return .original }
        return .mp3(kbps: ceiling)
    }

    /// Containers iOS cannot decode natively. Kept explicit rather than inverted from
    /// a supported list, so a container that merely lacks a MIME mapping is not
    /// needlessly transcoded.
    static func needsTranscode(_ suffix: String?) -> Bool {
        ["ogg", "oga", "opus", "wma", "ape", "wv"].contains(suffix?.lowercased() ?? "")
    }

    /// The server request for a variant: the endpoint and its query.
    ///
    /// `raw` for the original, never a transcode at full rate: a transcoded response is
    /// chunked with no Content-Length and no byte ranges, which breaks seeking.
    static func streamQuery(for song: Song, variant: StreamVariant) -> [String: String] {
        switch variant {
        case .original:
            return ["id": song.id, "format": "raw"]
        case let .mp3(kbps):
            return ["id": song.id, "format": "mp3", "maxBitRate": String(kbps)]
        }
    }
}
