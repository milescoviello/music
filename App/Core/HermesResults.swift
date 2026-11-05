import Foundation

/// What Hermes writes back, and the shape of waiting for it.
///
/// Foundation-only and free of networking on purpose: these types are compiled into the
/// test package, so the decoding rules and the title sanitiser are covered by `swift test`
/// rather than by trying something on the phone and squinting at it.
///
/// Every payload carries `status`. `"ok"` means the agent finished the job; `"error"` means
/// it tried and could not, and `message` says why. **The absence of a file is neither** —
/// it means the run is still going, which is why `HermesOutcome` has a `pending` case
/// rather than treating a missing answer as failure.
///
/// Wire keys are written out in full rather than left to
/// `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase`. That strategy turns
/// `song_id` into `songId`, which does **not** match a property spelled `songID` — the
/// house spelling everywhere else in this app — so the field decodes as `nil` and nothing
/// warns you. Spelling the keys out also means the prompt that tells the agent what to
/// emit can be diffed against these declarations line for line.
enum HermesOutcome<Value: Sendable>: Sendable {
    case pending
    case ok(Value)
    case failed(String)
}

/// Common shape. `status` is the discriminator; everything else is per-feature.
protocol HermesPayload: Decodable, Sendable {
    var status: String { get }
    var message: String? { get }
}

extension HermesPayload {
    var isOK: Bool { status == "ok" }
    /// What to show when the agent reported a failure but said nothing useful.
    var failureText: String {
        message?.isEmpty == false ? message! : "Hermes couldn't do that."
    }
}

/// Feature D3 — a playlist Hermes built from a described vibe.
struct VibeResult: HermesPayload {
    let status: String
    var message: String?
    var playlistID: String?
    var playlistName: String?
    var trackCount: Int?
    /// A sentence on what it went for, also mirrored into the playlist's comment.
    var note: String?

    enum CodingKeys: String, CodingKey {
        case status, message, note
        case playlistID = "playlist_id"
        case playlistName = "playlist_name"
        case trackCount = "track_count"
    }
}

/// Feature D2 — lyric search hits.
struct LyricSearchResult: HermesPayload {
    let status: String
    var message: String?
    var query: String?
    var matches: [LyricMatch]?

    /// An empty list is a real answer, not a failure: the library genuinely has no
    /// matching lyric on file.
    var found: [LyricMatch] { matches ?? [] }
}

struct LyricMatch: Codable, Hashable, Sendable, Identifiable {
    let songID: String
    var title: String?
    var artist: String?
    var album: String?
    /// The matching line, already stripped of any timestamp prefix.
    var line: String?
    /// Milliseconds into the track, when the lyric was timed. Enables "play from here".
    var atMs: Int?

    var id: String { songID }

    enum CodingKeys: String, CodingKey {
        case title, artist, album, line
        case songID = "song_id"
        case atMs = "at_ms"
    }
}

/// Feature D1 — a written note about a record or an artist.
struct HermesNote: Codable, Sendable, HermesPayload {
    let status: String
    var message: String?
    var kind: String?
    var name: String?
    var text: String?
    var sources: [String]?
    var writtenAt: Date?

    var paragraphs: [String] {
        (text ?? "")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    enum CodingKeys: String, CodingKey {
        case status, message, kind, name, text, sources
        case writtenAt = "written_at"
    }
}

/// What a note is about. Doubles as its cache identity.
enum HermesNoteSubject: Hashable, Codable, Sendable {
    case album(id: String, name: String, artist: String?)
    case artist(id: String, name: String)

    var kind: String {
        switch self {
        case .album: return "album"
        case .artist: return "artist"
        }
    }

    var id: String {
        switch self {
        case let .album(id, _, _): return id
        case let .artist(id, _): return id
        }
    }

    var name: String {
        switch self {
        case let .album(_, name, _): return name
        case let .artist(_, name): return name
        }
    }

    var artist: String? {
        switch self {
        case let .album(_, _, artist): return artist
        case .artist: return nil
        }
    }
}

/// Feature D4 — the library health report.
struct HealthReport: HermesPayload, Codable {
    let status: String
    var message: String?
    var scannedAt: Date?
    var totalTracks: Int?
    var duplicateGroups: [DuplicateGroup]?
    var undecodable: [HealthTrack]?
    var missingYear: Int?
    var missingArtwork: Int?

    enum CodingKeys: String, CodingKey {
        case status, message, undecodable
        case scannedAt = "scanned_at"
        case totalTracks = "total_tracks"
        case duplicateGroups = "duplicate_groups"
        case missingYear = "missing_year"
        case missingArtwork = "missing_artwork"
    }

    struct DuplicateGroup: Codable, Hashable, Sendable, Identifiable {
        var title: String
        var artist: String?
        var copies: [HealthTrack]
        /// Stable across reports, so a list does not reshuffle on refresh.
        var id: String { "\(artist ?? "")|\(title)" }
    }

    struct HealthTrack: Codable, Hashable, Sendable, Identifiable {
        let songID: String
        var path: String?
        var library: String?
        var suffix: String?
        var sizeBytes: Int64?
        var id: String { songID }

        enum CodingKeys: String, CodingKey {
            case path, library, suffix
            case songID = "song_id"
            case sizeBytes = "size_bytes"
        }
    }
}

/// Turns "late night drive" into "Late Night Drive".
///
/// The name is dictated to Hermes rather than chosen by it, because it is the fallback
/// signal: if the results file never lands, a playlist with exactly this name appearing on
/// the server is how the app knows the job succeeded. That only works if the app decided
/// the name up front.
enum VibeTitle {
    static func sanitised(_ vibe: String) -> String {
        let words = vibe
            .replacingOccurrences(of: "[\\n\\r\\t]+", with: " ", options: .regularExpression)
            .components(separatedBy: " ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let titled = words.prefix(6).map { word -> String in
            // Words already shouting are left alone; "DJ MOTH" should not become "Dj Moth".
            if word.count > 1, word == word.uppercased() { return word }
            return word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }

        let joined = titled.joined(separator: " ")
        return joined.isEmpty ? "Mix" : String(joined.prefix(60))
    }

    /// Appends a short suffix when the name is already taken, so the fallback stays
    /// unambiguous.
    static func unique(_ base: String, existing: [String], requestID: UUID) -> String {
        guard existing.contains(where: { $0.compare(base, options: .caseInsensitive) == .orderedSame })
        else { return base }
        return "\(base) · \(requestID.uuidString.prefix(4))"
    }
}
