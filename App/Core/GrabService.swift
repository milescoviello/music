import Foundation
import Observation

/// Music asked for from the app (`GrabClient`): sent, watched until it is in the library or
/// has failed, and picked a copy for when that was wanted.
///
/// Watched closely -- every few seconds -- while the Requests screen or a copy picker is
/// open, and every half minute while anything is still under way; not at all otherwise.
@MainActor
@Observable
final class GrabService {
    private static let libraryKey = "grab.lastLibrary"

    /// The server can take requests: sonic answers, and relays to music-grab.
    private(set) var isAvailable = false
    private(set) var requests: [SonicClient.GrabRequest] = []
    /// What has just landed, for a moment's notice on screen.
    private(set) var landed: SonicClient.GrabRequest?

    /// What a menu asked to get, and which screen shows the Add sheet for it: the one on
    /// top, as with Add to Playlist (`PlaylistStore.picking`).
    struct Adding: Identifiable, Equatable {
        let item: AddMusicItem
        let host: String

        var id: String { item.id }
    }

    var adding: Adding?

    /// The library chosen last in the Add sheet, which it starts on next time.
    var lastLibrary: SonicClient.Library {
        didSet { UserDefaults.standard.set(lastLibrary.rawValue, forKey: Self.libraryKey) }
    }

    /// Asked for and not finished: under way, or waiting for a copy to be picked.
    var openCount: Int { requests.filter { $0.state.isActive || $0.state == .choosing }.count }

    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var closeWatchers = 0
    @ObservationIgnored private var lastCheck: Date?
    /// Requests already known to be over, so a landing is noticed once.
    @ObservationIgnored private var over: Set<String> = []

    init() {
        lastLibrary = UserDefaults.standard.string(forKey: Self.libraryKey)
            .flatMap(SonicClient.Library.init(rawValue:)) ?? .music
    }

    func configure(appState: AppState) {
        self.appState = appState
    }

    private var client: SonicClient {
        SonicClient(configuration: appState?.sonic.configuration ?? .default)
    }

    /// At most once a minute unless forced, on launch and foreground like sonic's status; a
    /// failed check is tried again after ten seconds, as launch can come before the network.
    func refreshAvailability(force: Bool = false) async {
        if !force, let lastCheck, Date.now.timeIntervalSince(lastCheck) < (isAvailable ? 60 : 10) { return }
        lastCheck = .now
        isAvailable = await client.grabAvailable()
        if isAvailable { await refresh() }
    }

    func refresh() async {
        guard let fresh = try? await client.grabRequests() else { return }
        let firstLook = requests.isEmpty && over.isEmpty
        for request in fresh where !request.state.isActive && request.state != .choosing {
            guard over.insert(request.id).inserted, !firstLook else { continue }
            await note(request)
        }
        requests = fresh
        keepWatching()
    }

    /// One request with every copy found, for the picker.
    func details(_ id: String) async -> SonicClient.GrabRequest? {
        let found = try? await client.grabRequest(id)
        if let found { replace(found) }
        return found
    }

    @discardableResult
    func ask(_ ask: SonicClient.GrabAsk) async throws -> SonicClient.GrabRequest {
        let request = try await client.ask(ask)
        if ask.replace == nil { lastLibrary = ask.library }
        requests.insert(request, at: 0)
        await Diagnostics.shared.record("requests", "asked for the \(ask.kind.rawValue) “\(ask.title)” by \(ask.artist)"
            + (ask.albumToo ? ", then its album" : "") + (ask.replace != nil ? ", lossless in place" : "")
            + " into \(ask.library == .music ? "Music" : "My Music")" + (ask.choose ? ", to pick the copy" : ""))
        keepWatching()
        return request
    }

    @discardableResult
    func choose(_ request: SonicClient.GrabRequest, target: String, copy: Int) async throws -> SonicClient.GrabRequest {
        let fresh = try await client.choose(request: request.id, target: target, copy: copy)
        replace(fresh)
        keepWatching()
        return fresh
    }

    func retry(_ request: SonicClient.GrabRequest) async throws {
        replace(try await client.retry(request: request.id))
        over.remove(request.id)
        keepWatching()
    }

    func cancel(_ request: SonicClient.GrabRequest) async throws {
        replace(try await client.cancel(request: request.id))
        over.insert(request.id)
    }

    func dismissLanded() {
        landed = nil
    }

    /// The Requests screen and the copy picker watch closely while they are open.
    func beginWatchingClosely() {
        closeWatchers += 1
        keepWatching()
    }

    func endWatchingClosely() {
        closeWatchers = max(0, closeWatchers - 1)
    }

    private func replace(_ request: SonicClient.GrabRequest) {
        if let index = requests.firstIndex(where: { $0.id == request.id }) {
            requests[index] = request
        } else {
            requests.insert(request, at: 0)
        }
    }

    private func note(_ request: SonicClient.GrabRequest) async {
        let name = "“\(request.title ?? "")” by \(request.artist ?? "")"
        switch request.state {
        case .done:
            landed = request
            await Diagnostics.shared.record("requests", "\(name): \(request.detail.lowercased())")
        case .failed:
            await Diagnostics.shared.record("requests", "\(name): \(request.detail.lowercased())")
        default:
            break
        }
    }

    private func keepWatching() {
        let busy = requests.contains { $0.state.isActive }
        guard watcher == nil, busy || closeWatchers > 0 else { return }
        watcher = Task { [weak self] in
            while let self, !Task.isCancelled {
                let close = self.closeWatchers > 0
                guard close || self.requests.contains(where: { $0.state.isActive }) else { break }
                try? await Task.sleep(for: .seconds(close ? 3 : 30))
                await self.refresh()
            }
            self?.watcher = nil
        }
    }
}
