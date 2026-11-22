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

    /// When the service could not be asked about a song: not asked again for a while. It
    /// used to count as the song having no word timing until the app was next launched, so
    /// a song first opened offline never lit up word by word that session.
    private var failedAt: [String: Date] = [:]
    static let failureRetry: TimeInterval = 120

    /// `keep`: the song is downloaded, so what the service says is kept with it, for
    /// offline. A downloaded song's kept timing is used without asking.
    func cues(for songID: String, lines: [LyricLine], sonic: SonicClient.Configuration, keep: Bool = false) async -> [Int: [WordCue]] {
        guard lines.contains(where: { $0.start != nil }) else { return [:] }
        if kept[songID] == nil, let stored = await LyricsStore.shared.words(songID: songID) {
            remember(songID, stored)
        }
        if kept[songID] == nil, failedAt[songID].map({ Date.now.timeIntervalSince($0) >= Self.failureRetry }) ?? true {
            do {
                let found = try await SonicClient(configuration: sonic).words(songID: songID) ?? []
                remember(songID, found)
                if keep { await LyricsStore.shared.saveWords(found, for: songID) }
            } catch {
                failedAt[songID] = .now
            }
        }
        return WordTiming.align(lines, with: kept[songID] ?? [])
    }

    private func remember(_ songID: String, _ lines: [SonicClient.WordLine]) {
        kept[songID] = lines
        failedAt[songID] = nil
        order.append(songID)
        if order.count > 30 { kept[order.removeFirst()] = nil }
    }
}
