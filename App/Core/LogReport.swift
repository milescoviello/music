import Foundation

/// What Send Logs sends: what the app was doing and what has gone wrong, as one plain-text
/// report, kept on the server so a bug can be looked into without the device in hand.
///
/// Built from values rather than from the app's state, so it is tested on its own;
/// `AppState.logReport` fills it in. Like the failure log it carries, it never holds the
/// password, the auth token or a request's query.
struct LogReport: Sendable, Equatable {
    struct Row: Sendable, Equatable {
        var label: String
        var value: String
    }

    struct Section: Sendable, Equatable {
        var title: String
        var rows: [Row]
    }

    var sentAt: Date
    /// The build, as Settings shows it.
    var app: String
    var system: String
    /// What the person sending it says went wrong.
    var note: String
    var sections: [Section]
    /// `Diagnostics.export()`: the log, oldest first.
    var log: String

    /// The platform, and on Linux which machine, for the name the server files it under.
    static var source: String {
        #if os(Linux)
        "linux-\(ProcessInfo.processInfo.hostName)"
        #elseif os(iOS)
        "ios"
        #else
        "macos"
        #endif
    }

    static var currentSystem: String {
        #if os(Linux)
        let platform = "Linux"
        #elseif os(iOS)
        let platform = "iOS"
        #else
        let platform = "macOS"
        #endif
        // Apple's reads "Version 27.0.1 (Build 24A446)", which made "iOS Version 27.0.1".
        var version = ProcessInfo.processInfo.operatingSystemVersionString
        if version.hasPrefix("Version ") { version.removeFirst("Version ".count) }
        return "\(platform) \(version)"
    }

    /// The report as it is sent. Times are the device's own, with its zone named once at
    /// the top; the failure log's times are in the same zone.
    func text(in zone: TimeZone = .current) -> String {
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = zone
        local.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        let utc = ISO8601DateFormatter()

        var lines = [
            "Music logs",
            "Sent: \(local.string(from: sentAt)) (\(utc.string(from: sentAt)))",
            "App: \(app)",
            "System: \(system)",
        ]
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            lines += ["", "What went wrong:"] + trimmed.components(separatedBy: .newlines).map { "  \($0)" }
        }
        for section in sections where !section.rows.isEmpty {
            lines += ["", "\(section.title):"] + section.rows.map { "  \($0.label): \($0.value)" }
        }
        lines += ["", "Log, oldest first:", log.isEmpty ? "  Nothing logged yet." : log]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Why a report didn't arrive, in words: `SonicError` on its own reads as "error 2".
    static func failure(_ error: any Error) -> String {
        switch error as? SonicError {
        case .status(404): "The sonic service on the server needs updating before it can take logs."
        case .status(401): "The sonic service wants a token. Set it in Sonic Analysis settings."
        case .status(413): "The report is too big for the server."
        case .status(let code): "The sonic service answered \(code)."
        case .badURL: "The sonic service's address isn't valid. Check it in Sonic Analysis settings."
        case .notFound, nil: error.localizedDescription
        }
    }

    /// "1:05", "1:02:03": a position in a track.
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "?" }
        let whole = Int(seconds)
        let (hours, minutes, rest) = (whole / 3600, whole / 60 % 60, whole % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}
