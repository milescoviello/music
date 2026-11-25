import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Soulseek side of getting music, watched from the app: slskd itself (signed in or
/// not, what it shares, what it is sending), its downloads by folder, and the imports that
/// copy a finished download into the library. `music-grab serve` puts it together on the
/// server from slskd's own API and the jobs' files; sonic relays it, as `/v1/grab/slskd`.
///
/// The sentences are here rather than in either app, so the phone and the desktop say the
/// same thing.
extension SonicClient {
    struct SlskdMonitor: Decodable, Equatable, Sendable {
        let slskd: SlskdStatus
        /// music-grab jobs with a watcher running: downloads being followed to the library.
        let running: Int
        let downloads: SlskdDownloads
        let imports: [SlskdImport]
    }

    struct SlskdStatus: Decodable, Equatable, Sendable {
        /// slskd answered at all.
        let reachable: Bool
        let state: String?
        let connected: Bool?
        let loggedIn: Bool?
        let server: String?
        let username: String?
        let version: String?
        let updateAvailable: Bool?
        let shares: Shares?
        let uploads: Uploads?
        let error: String?

        struct Shares: Decodable, Equatable, Sendable {
            let files: Int?
            let folders: Int?
            let scanning: Bool
            let ready: Bool
        }

        struct Uploads: Decodable, Equatable, Sendable {
            let sending: Int
            let waiting: Int
            /// Bytes a second, all uploads together.
            let speed: Double
        }

        var isOnline: Bool { reachable && loggedIn == true }
    }

    struct SlskdDownloads: Decodable, Equatable, Sendable {
        let downloading: Int
        let queued: Int
        /// Bytes a second, every download together.
        let speed: Double
        /// Under way first, then the last week's finished ones, newest first.
        let folders: [SlskdFolder]
    }

    /// One sharer's folder being downloaded: slskd groups its files that way.
    struct SlskdFolder: Decodable, Equatable, Sendable, Identifiable {
        let id: String
        let user: String
        let folder: String
        let state: State
        let files: Int
        let filesDone: Int
        let filesFailed: Int
        let bytes: Int64
        let bytesDone: Int64
        let speed: Double
        /// When a file in it last started or ended (seconds since 1970).
        let at: Double?
        /// slskd's reason, for a file that did not come.
        let why: String?
        /// The music-grab job it is for, when one asked for it; "Music app" for the app's.
        let job: String?
        let source: String?
        let items: [SlskdFile]

        enum State: String, Decodable, Sendable {
            case downloading, queued, done, partial, failed

            init(from decoder: Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = State(rawValue: raw) ?? .failed
            }
        }

        var fraction: Double { bytes > 0 ? min(1, Double(bytesDone) / Double(bytes)) : 0 }
        var date: Date? { at.map { Date(timeIntervalSince1970: $0) } }
    }

    struct SlskdFile: Decodable, Equatable, Sendable, Identifiable {
        let name: String
        /// slskd's own words: "InProgress", "Queued, Remotely", "Completed, Succeeded"...
        let state: String
        let bytes: Int64
        let bytesDone: Int64
        let why: String?

        var id: String { name }
    }

    /// A finished download on its way into the library, or in it.
    struct SlskdImport: Decodable, Equatable, Sendable, Identifiable {
        let id: String
        let job: String
        let source: String
        let kind: String
        let artist: String?
        let title: String?
        let library: String?
        let state: State
        let detail: String
        let at: Double?
        let files: Int?
        /// Files the fake-FLAC check flagged and let through.
        let flagged: Int
        /// Where it went, inside its library.
        let folder: String?

        enum State: String, Decodable, Sendable {
            case importing, indexing, done, failed, held

            init(from decoder: Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = State(rawValue: raw) ?? .failed
            }

            var isUnderWay: Bool { self == .importing || self == .indexing }
        }

        var date: Date? { at.map { Date(timeIntervalSince1970: $0) } }
    }

    func slskdMonitor() async throws -> SlskdMonitor? {
        try await getIfPresent("v1/grab/slskd", [:], as: SlskdMonitor.self, timeout: 20)
    }
}

// MARK: - What the screens say

extension SonicClient.SlskdStatus {
    /// "Connected as name", or what is wrong.
    var headline: String {
        guard reachable else { return "slskd isn't answering" }
        if loggedIn == true { return username.map { "Connected as \($0)" } ?? "Connected" }
        if connected == true { return "Connected, not signed in" }
        return "Not connected to Soulseek"
    }

    /// The server it is signed in at, or slskd's own words for where it stands.
    var connectionLine: String? {
        guard reachable else { return error }
        if loggedIn == true { return server.map { "Signed in at \($0)" } }
        return [state, server].compactMap { $0 }.joined(separator: " · ")
    }

    var sharingLine: String? {
        guard let shares, let files = shares.files else { return nil }
        let folders = shares.folders.map { " in \(SlskdText.count($0, "folder"))" } ?? ""
        return "\(SlskdText.count(files, "file"))\(folders)" + (shares.scanning ? " · scanning" : "")
    }

    var uploadsLine: String? {
        guard let uploads else { return nil }
        guard uploads.sending + uploads.waiting > 0 else { return "Nothing being sent" }
        var parts = ["\(uploads.sending) sending"]
        if uploads.waiting > 0 { parts.append("\(uploads.waiting) waiting") }
        if uploads.speed > 0 { parts.append(SlskdText.speed(uploads.speed)) }
        return parts.joined(separator: " · ")
    }
}

extension SonicClient.SlskdMonitor {
    /// The one line a summary row shows: what is moving, else what is waiting, else quiet.
    var activityLine: String {
        var parts: [String] = []
        if downloads.downloading > 0 { parts.append("\(downloads.downloading) downloading") }
        if downloads.queued > 0 { parts.append("\(downloads.queued) waiting") }
        let importing = imports.filter { $0.state.isUnderWay }.count
        if importing > 0 { parts.append("\(importing) importing") }
        if downloads.speed > 0 { parts.append(SlskdText.speed(downloads.speed)) }
        return parts.isEmpty ? "Nothing downloading" : parts.joined(separator: " · ")
    }
}

extension SonicClient.SlskdFolder {
    /// Whose it is and what it is for.
    var sourceLine: String {
        [user, source].compactMap { $0 }.joined(separator: " · ")
    }

    /// Where it stands, in a line.
    func detailLine(now: Date = .now) -> String {
        switch state {
        case .downloading:
            var parts = ["\(filesDone) of \(SlskdText.count(files, "file"))",
                         "\(SlskdText.bytes(bytesDone)) of \(SlskdText.bytes(bytes))"]
            if speed > 0 { parts.append(SlskdText.speed(speed)) }
            return parts.joined(separator: " · ")
        case .queued:
            return filesDone > 0
                ? "\(filesDone) of \(SlskdText.count(files, "file")) · the rest waiting in \(user)'s queue"
                : "Waiting in \(user)'s queue · \(SlskdText.count(files, "file")), \(SlskdText.bytes(bytes))"
        case .done:
            return ["\(SlskdText.count(files, "file")), \(SlskdText.bytes(bytes))", SlskdText.ago(date, now: now)]
                .compactMap { $0 }.joined(separator: " · ")
        case .partial:
            return ["\(filesDone) of \(SlskdText.count(files, "file")) came; \(filesFailed) didn't" + (why.map { ": \($0)" } ?? ""),
                    SlskdText.ago(date, now: now)].compactMap { $0 }.joined(separator: " · ")
        case .failed:
            return ["Failed" + (why.map { ": \($0)" } ?? ""), SlskdText.ago(date, now: now)]
                .compactMap { $0 }.joined(separator: " · ")
        }
    }
}

extension SonicClient.SlskdFile {
    /// slskd's state in plain words, with how far it has got.
    var stateLine: String {
        switch state {
        case let s where s.hasPrefix("InProgress"):
            let percent = bytes > 0 ? Int(Double(bytesDone) / Double(bytes) * 100) : 0
            return "\(percent)% of \(SlskdText.bytes(bytes))"
        case let s where s.hasPrefix("Queued"):
            return s.contains("Remotely") ? "In the sharer's queue" : "Waiting to start"
        case let s where s.hasPrefix("Requested") || s.hasPrefix("Initializing"):
            return "Starting"
        case "Completed, Succeeded":
            return SlskdText.bytes(bytes)
        default:
            let what = state.replacingOccurrences(of: "Completed, ", with: "")
            return what + (why.map { ": \($0)" } ?? "")
        }
    }

    var didFail: Bool { state.hasPrefix("Completed") && state != "Completed, Succeeded" }
}

extension SonicClient.SlskdImport {
    /// Who, what, and which library.
    var subtitle: String {
        [artist, kind == "album" ? "Album" : "Song",
         library == "my_music" ? "My Music" : library == "music" ? "Music" : nil, source]
            .compactMap { $0 }.joined(separator: " · ")
    }

    func detailLine(now: Date = .now) -> String {
        var parts = [detail]
        if state == .done, let files { parts.append(SlskdText.count(files, "file")) }
        if flagged > 0 { parts.append("\(flagged) flagged by the fake-FLAC check") }
        if let ago = SlskdText.ago(date, now: now) { parts.append(ago) }
        return parts.joined(separator: " · ")
    }
}

enum SlskdText {
    /// "68,633 files". Grouped by hand: the Linux Foundation has no `formatted()`.
    static func count(_ n: Int, _ noun: String) -> String {
        var digits = String(abs(n))
        var groups: [String] = []
        while digits.count > 3 {
            groups.insert(String(digits.suffix(3)), at: 0)
            digits.removeLast(3)
        }
        groups.insert(digits, at: 0)
        return "\(n < 0 ? "-" : "")\(groups.joined(separator: ",")) \(noun)\(n == 1 ? "" : "s")"
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        "\(bytes(Int64(bytesPerSecond)))/s"
    }

    /// "5 min ago", "yesterday"; nothing for an unknown time.
    static func ago(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3_600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3_600)) hr ago"
        default:
            let days = Int(seconds / 86_400)
            return days == 1 ? "yesterday" : "\(days) days ago"
        }
    }
}
