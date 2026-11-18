import Foundation
import Observation
import WatchConnectivity

/// The watch's view of the phone (`WatchLink.State`, sent by the phone's `WatchBridge`),
/// the commands it sends back, and the songs it keeps for playing with no phone at all.
@MainActor
@Observable
final class WatchModel {
    static let shared = WatchModel()

    private(set) var state = WatchLink.State()
    private(set) var cover: Data?
    private(set) var isReachable = false
    /// The songs on the watch, in the order they were kept.
    private(set) var kept: [WatchLink.Track] = []
    /// A collection asked for and still arriving: its name and how many songs it holds.
    private(set) var expected: [String: (name: String, total: Int)] = [:]
    /// Something to say for a moment: "iPhone isn't nearby".
    var notice: String?

    @ObservationIgnored private let link = LinkDelegate()

    /// A group of kept songs: what they were kept for.
    struct Collection: Identifiable {
        let id: String
        let name: String
        let tracks: [WatchLink.Track]
        let total: Int
        var isComplete: Bool { tracks.count >= total }
    }

    var collections: [Collection] {
        var order: [String] = []
        var grouped: [String: [WatchLink.Track]] = [:]
        for track in kept {
            if grouped[track.collection] == nil { order.append(track.collection) }
            grouped[track.collection, default: []].append(track)
        }
        for id in expected.keys where grouped[id] == nil {
            order.append(id)
            grouped[id] = []
        }
        return order.map { id in
            let tracks = (grouped[id] ?? []).sorted { $0.index < $1.index }
            let name = tracks.first?.collectionName ?? expected[id]?.name ?? "Playlist"
            let total = max(tracks.first?.total ?? 0, expected[id]?.total ?? 0, tracks.count)
            return Collection(id: id, name: name, tracks: tracks, total: total)
        }
    }

    private init() {
        kept = Self.loadCatalog().filter { FileManager.default.fileExists(atPath: Self.file(for: $0.id).path) }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = link
        WCSession.default.activate()
    }

    // MARK: - Talking to the phone

    /// Playing and skipping only mean something now, so they need the phone in reach;
    /// keeping a playlist can wait, and is queued for when it is.
    func send(_ command: WatchLink.Command) {
        guard let data = WatchLink.encode(command), WCSession.isSupported() else { return }
        let session = WCSession.default
        switch command {
        case .keep, .stopKeeping:
            session.transferUserInfo([WatchLink.commandKey: data])
        default:
            guard session.activationState == .activated, session.isReachable else {
                notice = "iPhone isn't nearby"
                return
            }
            session.sendMessage([WatchLink.commandKey: data], replyHandler: nil) { [weak self] _ in
                Task { @MainActor in self?.notice = "iPhone didn't answer" }
            }
        }
    }

    func keep(_ item: WatchLink.Item) {
        expected[item.id] = (item.name, Int(item.detail?.split(separator: " ").first ?? "") ?? 0)
        send(.keep(item))
    }

    /// Takes a collection off the watch, and stops what is still on its way.
    func remove(_ id: String) {
        send(.stopKeeping(id))
        expected[id] = nil
        for track in kept where track.collection == id {
            try? FileManager.default.removeItem(at: Self.file(for: track.id))
        }
        kept.removeAll { $0.collection == id }
        saveCatalog()
    }

    fileprivate func received(state: WatchLink.State?, cover: Data?) {
        if let state { self.state = state }
        if let cover { self.cover = cover }
    }

    fileprivate func reachability(_ reachable: Bool) {
        isReachable = reachable
    }

    fileprivate func arrived(_ track: WatchLink.Track) {
        kept.removeAll { $0.id == track.id && $0.collection == track.collection }
        kept.append(track)
        if kept.filter({ $0.collection == track.collection }).count >= track.total {
            expected[track.collection] = nil
        }
        saveCatalog()
    }

    // MARK: - On the watch's disk

    /// Application Support, which the system leaves alone, rather than a cache.
    nonisolated static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Kept", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    nonisolated static func file(for id: String) -> URL {
        let safe = id.replacingOccurrences(of: "/", with: "_")
        return folder.appendingPathComponent("\(safe).mp3")
    }

    private static var catalogURL: URL { folder.appendingPathComponent("catalog.json") }

    private static func loadCatalog() -> [WatchLink.Track] {
        guard let data = try? Data(contentsOf: catalogURL) else { return [] }
        return (try? JSONDecoder().decode([WatchLink.Track].self, from: data)) ?? []
    }

    private func saveCatalog() {
        guard let data = try? JSONEncoder().encode(kept) else { return }
        try? data.write(to: Self.catalogURL, options: .atomic)
    }
}

/// WatchConnectivity calls in on its own queue; this hands what it says to the model on
/// the main actor, after doing what cannot wait (a received file is deleted the moment
/// its callback returns, so it is moved here and now).
private final class LinkDelegate: NSObject, WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        let state = WatchLink.decode(WatchLink.State.self, from: context[WatchLink.stateKey])
        let cover = context[WatchLink.coverKey] as? Data
        let reachable = session.isReachable
        Task { @MainActor in
            WatchModel.shared.received(state: state, cover: cover)
            WatchModel.shared.reachability(reachable)
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let state = WatchLink.decode(WatchLink.State.self, from: applicationContext[WatchLink.stateKey])
        let cover = applicationContext[WatchLink.coverKey] as? Data
        Task { @MainActor in WatchModel.shared.received(state: state, cover: cover) }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in WatchModel.shared.reachability(reachable) }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let track = WatchLink.decode(WatchLink.Track.self, from: file.metadata?[WatchLink.trackKey]) else { return }
        let destination = WatchModel.file(for: track.id)
        try? FileManager.default.removeItem(at: destination)
        guard (try? FileManager.default.moveItem(at: file.fileURL, to: destination)) != nil else { return }
        Task { @MainActor in WatchModel.shared.arrived(track) }
    }
}
