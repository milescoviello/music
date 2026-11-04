import Foundation
import Observation

/// New releases by the artists actually played, that the library does not have, from the
/// sonic service's radar; one tap asks Hermes to get one.
@MainActor
@Observable
final class ReleaseRadar {
    private static let requestedKey = "radar.requested"

    private(set) var items: [SonicClient.RadarItem] = []
    /// The service is working out a newer answer; asked again in a minute and a half.
    private(set) var isRefreshing = false
    /// Asked for already, by release id, so a card says so.
    private(set) var requested: Set<String>

    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private var lastLoad: Date?

    init() {
        requested = Set(UserDefaults.standard.stringArray(forKey: Self.requestedKey) ?? [])
    }

    func attach(_ appState: AppState) {
        self.appState = appState
    }

    /// At most every ten minutes: the service's answer changes once a day.
    func load() async {
        guard let appState else { return }
        if let lastLoad, Date.now.timeIntervalSince(lastLoad) < 600 { return }
        lastLoad = .now
        guard let answer = try? await SonicClient(configuration: appState.sonic.configuration).radar() else {
            lastLoad = nil
            return
        }
        items = answer.items
        isRefreshing = answer.refreshing
        if answer.refreshing {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 90 * 1_000_000_000)
                self?.lastLoad = nil
                await self?.load()
            }
        }
    }

    /// Whether requests can be sent at all: Hermes set up in Settings.
    var canRequest: Bool { appState?.requests.configuration != nil }

    func request(_ item: SonicClient.RadarItem) async -> Bool {
        guard let appState else { return false }
        let kind: String
        switch item.type {
        case "Album": kind = "the album"
        case "Single": kind = "the single"
        case "EP": kind = "the EP"
        default: kind = ""
        }
        let text = "Get \(kind.isEmpty ? "" : kind + " ")“\(item.title)” by \(item.artist), released \(item.date)."
        let sent = await appState.requests.send(text)
        if sent {
            requested.insert(item.id)
            UserDefaults.standard.set(Array(requested), forKey: Self.requestedKey)
        }
        await Diagnostics.shared.record("radar", "\(sent ? "requested" : "could not request") “\(item.title)” by \(item.artist)")
        return sent
    }

    /// "Single · Oct 10", or "EP · Coming Dec 1".
    static func detail(_ item: SonicClient.RadarItem) -> String {
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: item.date) else { return item.type }
        let shown = DateFormatter()
        shown.setLocalizedDateFormatFromTemplate(
            Calendar.current.isDate(date, equalTo: .now, toGranularity: .year) ? "MMM d" : "MMM d yyyy"
        )
        return "\(item.type) · \(item.upcoming ? "Coming " : "")\(shown.string(from: date))"
    }
}
