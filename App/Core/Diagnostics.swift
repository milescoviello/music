import Foundation

/// A rolling log of what the app did and what went wrong, readable on the device and sent
/// whole by Send Logs.
///
/// This exists because of how this app is developed: there is no Mac, no simulator and
/// no debugger attached, so when something fails the only evidence is whatever the phone
/// can show for itself. Without this, "it didn't work" is unanswerable without plugging
/// in over USB and pulling crash reports — and a crash report says nothing about a
/// request that merely returned an error.
///
/// It began as failures only, which was too little to explain one: six cached downloads
/// failed one evening with nothing but their titles to go on — not the error, not how
/// long they had run, not whether the network had just changed. So it also keeps what
/// happened around a failure: network changes, launches, what played and from where,
/// stalls, interruptions. Never any credentials: it is meant to be sent and read.
///
/// Kept as JSON Lines, one entry appended per line. Rewriting the whole log for every
/// entry, as it once did, is a lot of writing once there is more to log, and an append
/// loses nothing to a crash. The file is cut back to the newest `limit` once it holds
/// `slack` more than that.
actor Diagnostics {
    static let shared = Diagnostics()

    struct Line: Codable, Sendable, Identifiable {
        var id = UUID()
        var at: Date
        var area: String
        var message: String
    }

    /// Days of ordinary use, and well under the most Send Logs may send.
    private let limit: Int
    private let slack: Int
    /// Newest first.
    private var lines: [Line] = []
    /// Entries in the file, which runs oldest first.
    private var onDisk = 0
    private let url: URL
    /// The log before it was JSON Lines: one array, newest first. Read once, then removed.
    private let legacyURL: URL
    private var didLoad = false
    /// Kept open: a launch logs dozens of lines, and opening the file for each was a
    /// measurable part of a slow machine's start.
    private var handle: FileHandle?
    private let encoder = JSONEncoder()

    init(directory: URL = Paths.root, limit: Int = 1_000, slack: Int = 250) {
        url = directory.appendingPathComponent("diagnostics.jsonl")
        legacyURL = directory.appendingPathComponent("diagnostics.json")
        self.limit = limit
        self.slack = slack
    }

    func record(_ area: String, _ message: String) {
        load()
        let line = Line(at: .now, area: area, message: Self.redact(message))
        lines.insert(line, at: 0)
        if lines.count > limit { lines.removeLast(lines.count - limit) }
        append(line)
    }

    /// Newest first.
    func recent() -> [Line] {
        load()
        return lines
    }

    func clear() {
        load()
        lines = []
        onDisk = 0
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: url)
    }

    /// Plain text, oldest first, for sharing or reading aloud.
    func export() -> String {
        load()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return lines.reversed().map { line in
            "\(formatter.string(from: line.at))  [\(line.area)]  \(line.message)"
        }.joined(separator: "\n")
    }

    /// Strips the query string from any URL in a message. Subsonic puts the username and
    /// an auth token in every request, so an unredacted URL in a shareable log would hand
    /// them out.
    static func redact(_ message: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\?[^\\s]*") else { return message }
        return regex.stringByReplacingMatches(
            in: message,
            range: NSRange(message.startIndex..., in: message),
            withTemplate: "?…"
        )
    }

    /// The words and the code: "The request timed out. (NSURLErrorDomain -1001)". The
    /// words alone are often vague, and the code tells a timeout from a refused
    /// connection from a dropped one.
    static func describe(_ error: any Error) -> String {
        let code = error as NSError
        return "\(error.localizedDescription) (\(code.domain) \(code.code))"
    }

    /// "0.4s", "42s", "2m10s", "1h03m".
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "?" }
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole)s" }
        if whole < 3600 { return String(format: "%dm%02ds", whole / 60, whole % 60) }
        return String(format: "%dh%02dm", whole / 3600, whole / 60 % 60)
    }

    // MARK: - Storage

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        let decoder = JSONDecoder()
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let stored = text.split(separator: "\n").compactMap { try? decoder.decode(Line.self, from: Data($0.utf8)) }
            onDisk = stored.count
            lines = stored.reversed()
        }
        if let data = try? Data(contentsOf: legacyURL) {
            // All older than anything in the new file.
            lines += (try? decoder.decode([Line].self, from: data)) ?? []
            if lines.count > limit { lines.removeLast(lines.count - limit) }
            rewrite()
            try? FileManager.default.removeItem(at: legacyURL)
        }
        if lines.count > limit { lines.removeLast(lines.count - limit) }
    }

    private func append(_ line: Line) {
        guard onDisk < limit + slack, var data = try? encoder.encode(line) else {
            rewrite()
            return
        }
        data.append(0x0A)
        if handle == nil { handle = try? FileHandle(forWritingTo: url) }
        guard let handle else {
            // No file yet, or it went: what is in memory is the log.
            rewrite()
            return
        }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            onDisk += 1
        } catch {
            rewrite()
        }
    }

    /// The log as it is in memory, in place of the file.
    private func rewrite() {
        // The open handle would go on writing to the file this replaces.
        try? handle?.close()
        handle = nil
        var data = Data()
        for line in lines.reversed() {
            guard let encoded = try? encoder.encode(line) else { continue }
            data.append(encoded)
            data.append(0x0A)
        }
        try? data.write(to: url, options: .atomic)
        onDisk = lines.count
    }
}
