import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Keeps the songs most likely to be played downloaded, in their original quality, so
/// they play from the device instead of over a connection that may give out.
///
/// Away from home everything comes through the tunnel at about a megabyte a second: a
/// lossless song takes a minute or two, and on 2026-11-03 a quarter of an hour of a
/// flaky link left ten songs in a row to stream as they came up. The most-played songs
/// are, by definition, most of what gets played, so having them here takes most
/// listening off the network altogether.
///
/// Which songs: the same ranking as Heavy Rotation (plays on every device, the play log,
/// recent ones weighted up), less the ones skipped early lately. A download group of its
/// own, so a song that falls out of the top is removed unless another download has it.
/// When: only while charging, and only while nothing is streaming, a few at a time, so
/// it never competes with what is playing.
@MainActor
@Observable
final class MostPlayedDownloads {
    static let groupID = "most-played"
    static let groupName = "Most Played"
    /// The sizes offered; 0 is off.
    static let choices = [0, 100, 300, 500, 1_000]

    private enum Key {
        static let count = "downloads.mostPlayed.count"
        static let wanted = "downloads.mostPlayed.wanted"
        static let refreshed = "downloads.mostPlayed.refreshed"
    }

    /// Queued at a time: enough to keep a charger busy, few enough that a song started
    /// meanwhile is not waiting behind an hour of them.
    private static let batch = 8
    /// Free space never used for this.
    private static let keepFree: Int64 = 8 << 30

    var count: Int {
        didSet {
            guard count != oldValue else { return }
            UserDefaults.standard.set(count, forKey: Key.count)
            SettingsLog.changed("Keep most played downloaded", from: Self.label(oldValue), to: Self.label(count))
            Task { await refresh(force: true) }
        }
    }

    /// The songs that should be here, best first.
    private(set) var wanted: [String]

    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private var isRefreshing = false
    /// Wanted, and not yet downloaded or on its way.
    @ObservationIgnored private var missing: [String] = []
    /// Why nothing is being fetched, logged once each time it changes.
    @ObservationIgnored private var lastHold: String?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var timer: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        count = defaults.object(forKey: Key.count) as? Int ?? 300
        wanted = defaults.stringArray(forKey: Key.wanted) ?? []
    }

    static func label(_ count: Int) -> String {
        count == 0 ? "off" : "\(count) songs"
    }

    func attach(_ appState: AppState) {
        self.appState = appState
        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        observers.append(NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.advance() }
        })
        #else
        // No notification for the charger here: a look every few minutes is plenty.
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                self?.advance()
            }
        }
        #endif
    }

    /// How many of the wanted songs are here now.
    var downloadedCount: Int {
        guard let catalog = appState?.downloads.catalog else { return 0 }
        return wanted.filter { catalog.entries[$0] != nil }.count
    }

    var downloadedBytes: Int64 {
        guard let catalog = appState?.downloads.catalog else { return 0 }
        return catalog.entries.values.filter { $0.isMember(of: Self.groupID) }.reduce(0) { $0 + $1.byteCount }
    }

    // MARK: - What should be here

    /// Once a day, at launch or on coming back, or at once when the size changes.
    func refresh(force: Bool = false) async {
        guard let appState, !isRefreshing else { return }
        if count == 0 {
            wanted = []
            missing = []
            UserDefaults.standard.removeObject(forKey: Key.wanted)
            if appState.downloads.hasDownload(group: Self.groupID) {
                appState.downloads.removeGroup(Self.groupID)
                await note("off: removing its songs")
            }
            return
        }
        let last = UserDefaults.standard.object(forKey: Key.refreshed) as? Date
        if !force, let last, Calendar.current.isDateInToday(last), !wanted.isEmpty {
            reconcile()
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }
        await appState.downloads.catalogLoaded()
        let ranked = await appState.rankPlays()
        // Offline, or the server not answering: what is here stays, and nothing is removed.
        guard !ranked.isEmpty else { return }
        let avoided = appState.skips.avoided()
        wanted = Array(ranked.lazy.filter { !avoided.contains($0.identity) }.compactMap(\.ids.first).prefix(count))
        UserDefaults.standard.set(wanted, forKey: Key.wanted)
        UserDefaults.standard.set(Date.now, forKey: Key.refreshed)
        await note("wants the top \(wanted.count) of \(ranked.count) played songs")
        reconcile()
    }

    /// Takes out what fell out of the top, files songs already downloaded for something
    /// else under this too, and lists what is left to fetch.
    private func reconcile() {
        guard let appState else { return }
        let downloads = appState.downloads
        let members = Set(downloads.catalog.songIDs(downloadedAs: Self.groupID))
        let target = Set(wanted)

        let leaving = members.subtracting(target)
        if !leaving.isEmpty {
            downloads.removeGroup(Self.groupID, songIDs: leaving)
            Task { await note("\(leaving.count) fell out of the top, removed unless another download has them") }
        }

        let present = wanted
            .filter { !members.contains($0) && downloads.status(for: $0) != .none }
            .compactMap { downloads.catalog.entries[$0]?.song ?? downloads.catalog.pending[$0]?.song }
        if !present.isEmpty {
            downloads.download(present, groupID: Self.groupID, groupName: Self.groupName)
        }

        missing = wanted.filter { downloads.status(for: $0) == .none }
        advance()
    }

    // MARK: - Fetching

    /// Queues the next few, if now is a good time. Called when a download finishes, a
    /// track starts, the charger is plugged in, and on a timer where there is no
    /// notification for that.
    @discardableResult
    func advance() -> Task<Void, Never>? {
        guard let appState, count > 0 else { return nil }
        let downloads = appState.downloads
        missing.removeAll { downloads.status(for: $0) != .none }
        guard !missing.isEmpty else { hold(nil); return nil }

        let inFlight = downloads.catalog.pending.values.filter { $0.isMember(of: Self.groupID) }.count
        guard inFlight < Self.batch / 2 else { return nil }
        guard PowerSource.isCharging else { hold("waiting for a charger"); return nil }
        guard !appState.player.isStreaming, appState.streamCache.fetchingSongID == nil else {
            hold("waiting while music streams")
            return nil
        }
        let free = Paths.availableBytes
        guard free == 0 || free > Self.keepFree else { hold("stopped: less than 8 GB free"); return nil }
        guard appState.reachability.network != .offline else { hold("waiting for a network"); return nil }

        hold(nil)
        let next = Array(missing.prefix(Self.batch - inFlight))
        missing.removeFirst(next.count)
        let left = missing.count
        return Task { [weak self] in
            var songs: [Song] = []
            for id in next {
                if let song = try? await appState.client.song(id: id) { songs.append(song) }
            }
            guard let self, !songs.isEmpty, count > 0 else { return }
            appState.downloads.download(songs, groupID: Self.groupID, groupName: Self.groupName)
            await note("queued \(songs.count), \(left) more to fetch")
        }
    }

    private func hold(_ reason: String?) {
        guard reason != lastHold else { return }
        lastHold = reason
        if let reason {
            let left = missing.count
            Task { await note("\(left) to fetch, \(reason)") }
        }
    }

    private func note(_ line: String) async {
        await Diagnostics.shared.record("most played", line)
    }
}

extension AppState {
    /// Every song with a play, ranked by how much lately: from the server's counts across
    /// all devices (the most played and the most recently played, so a song on repeat this
    /// week is in before it has many plays) and the play log here, early skips counting
    /// against. Heavy Rotation and the most-played downloads both read it.
    func rankPlays() async -> [MixEngine.Played] {
        async let most = native.mostPlayed(limit: 500)
        async let recent = native.recentlyPlayed(limit: 500)
        let counted = ((try? await most) ?? []) + ((try? await recent) ?? [])
        guard !counted.isEmpty else { return [] }
        await history.loaded()
        let local = history.plays.map {
            MixEngine.Sample(songID: $0.songID, artist: $0.artist, genre: $0.genre, at: $0.at)
        }
        let skipped = skips.penalties()
        let ranked = await Task.detached(priority: .userInitiated) {
            MixEngine.heavyRotation(
                counted: counted.map {
                    MixEngine.Counted(
                        id: $0.id, title: $0.title, artist: $0.artist,
                        plays: $0.playCount ?? 0, lastPlayed: $0.playDate
                    )
                },
                plays: local,
                skipped: skipped
            )
        }.value
        await Diagnostics.shared.record(
            "mixes", "played: \(counted.count) counted copies, \(ranked.count) songs ranked"
        )
        return ranked
    }
}

/// Whether the device is on a charger. Downloading hundreds of lossless songs is for then.
@MainActor
enum PowerSource {
    static var isCharging: Bool {
        #if canImport(UIKit)
        let state = UIDevice.current.batteryState
        return state == .charging || state == .full
        #else
        // Any mains supply online. A machine with no battery at all is always on power.
        let base = "/sys/class/power_supply"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base) else { return true }
        var sawMains = false
        for name in names {
            func read(_ file: String) -> String? {
                (try? String(contentsOfFile: "\(base)/\(name)/\(file)", encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard read("type") == "Mains" else { continue }
            sawMains = true
            if read("online") == "1" { return true }
        }
        return !sawMains
        #endif
    }
}
