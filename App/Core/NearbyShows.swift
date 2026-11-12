import Foundation
import Observation

/// Home's Shows Near You: concerts coming up nearby by the artists played most, from the
/// sonic service (`shows.py`), which has the Ticketmaster key. No key there, no shelf.
@MainActor
@Observable
final class NearbyShows {
    private(set) var items: [SonicClient.Show] = []

    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private var lastLoad: Date?

    func attach(_ appState: AppState) {
        self.appState = appState
    }

    /// At most every ten minutes: the service's answer changes once a day.
    func load() async {
        guard let appState else { return }
        if let lastLoad, Date.now.timeIntervalSince(lastLoad) < 600 { return }
        lastLoad = .now
        do {
            items = try await SonicClient(configuration: appState.sonic.configuration).shows() ?? []
        } catch {
            lastLoad = nil
        }
    }

    /// "Sat, Dec 5 · 8:00 PM", in the venue's own time, as the ticket says it.
    static func when(_ show: SonicClient.Show) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = show.time == nil ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm:ss"
        guard let date = parser.date(from: show.time.map { "\(show.date) \($0)" } ?? show.date) else { return show.date }
        let out = DateFormatter()
        out.dateFormat = show.time == nil ? "EEE, MMM d" : "EEE, MMM d · h:mm a"
        return out.string(from: date)
    }

    static func place(_ show: SonicClient.Show) -> String {
        [show.venue, show.city].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// Word-by-word timing for the lyrics on screen (`WordTiming`), one song's at a time,
/// kept for the songs seen lately so going back to one does not ask again.
@MainActor
final class WordTimingCache {
    private var kept: [String: [SonicClient.WordLine]] = [:]
    private var order: [String] = []

    func cues(for songID: String, lines: [LyricLine], sonic: SonicClient.Configuration) async -> [Int: [WordCue]] {
        guard lines.contains(where: { $0.start != nil }) else { return [:] }
        if kept[songID] == nil {
            let found = (try? await SonicClient(configuration: sonic).words(songID: songID)) ?? nil
            kept[songID] = found ?? []
            order.append(songID)
            if order.count > 30 { kept[order.removeFirst()] = nil }
        }
        return WordTiming.align(lines, with: kept[songID] ?? [])
    }
}
