import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The few pieces of Apple's Foundation that Linux's lacks and the Core uses, under the
// same names.

extension URLSession {
    /// Darwin's async form of `getAllTasks`.
    var allTasks: [URLSessionTask] {
        get async {
            await withCheckedContinuation { continuation in
                getAllTasks { tasks in
                    nonisolated(unsafe) let tasks = tasks
                    continuation.resume(returning: tasks)
                }
            }
        }
    }
}

/// "3 days ago", "in 2 hours", "yesterday": the English half of Darwin's formatter, which
/// is all the app ever shows.
final class RelativeDateTimeFormatter {
    enum UnitsStyle {
        case full, spellOut, short, abbreviated
    }

    var unitsStyle: UnitsStyle = .full

    func localizedString(for date: Date, relativeTo reference: Date) -> String {
        let seconds = date.timeIntervalSince(reference)
        let magnitude = abs(seconds)
        let units: [(Double, String, String)] = [
            (365 * 86_400, "year", "yr."),
            (30 * 86_400, "month", "mo."),
            (7 * 86_400, "week", "wk."),
            (86_400, "day", "day"),
            (3_600, "hour", "hr."),
            (60, "minute", "min."),
            (1, "second", "sec."),
        ]
        guard magnitude >= 1 else { return "now" }
        let (length, name, short) = units.first { magnitude >= $0.0 } ?? units.last!
        let count = Int(magnitude / length)
        if length == 86_400, count == 1, unitsStyle == .full || unitsStyle == .spellOut {
            return seconds < 0 ? "yesterday" : "tomorrow"
        }
        let unit: String
        switch unitsStyle {
        case .full, .spellOut: unit = count == 1 ? name : name + "s"
        case .short, .abbreviated: unit = short
        }
        return seconds < 0 ? "\(count) \(unit) ago" : "in \(count) \(unit)"
    }
}
