import Foundation
import Observation

/// Which of the server's music folders the UI is currently browsing.
///
/// `.all` is expressed by *omitting* `musicFolderId` from the request. Subsonic
/// treats an absent folder id as "every folder", so there is no fan-out, no merge
/// and no de-duplication to write -- the whole feature is one optional query
/// parameter threaded through the client.
enum LibraryScope: Hashable, Sendable {
    case all
    case folder(id: Int, name: String)

    var folderID: Int? {
        if case let .folder(id, _) = self { return id }
        return nil
    }

    /// `nil` means "do not send the parameter", i.e. all folders.
    var queryValue: String? {
        folderID.map(String.init)
    }

    var shortName: String {
        if case let .folder(_, name) = self { return name }
        return "All"
    }

    /// Part of a cache filename, so every cached list is scoped to the folder it came
    /// from. Defined once here because six screens need it and a per-screen version
    /// would eventually disagree with itself.
    var cacheKey: String {
        folderID.map(String.init) ?? "all"
    }
}

@MainActor
@Observable
final class LibraryScopeStore {
    private static let defaultsKey = "libraryScopeFolderID"
    private static let foldersKey = "libraryFolders"
    /// The daily mixes' own library, chosen apart from the one being browsed; -1 for all.
    nonisolated static let mixesKey = "mixes.folderID"

    private(set) var folders: [MusicFolder] = []

    /// Bumped on every change so views can key `.task(id:)` on it and reload.
    private(set) var generation = 0

    var scope: LibraryScope = .all {
        didSet {
            guard scope != oldValue else { return }
            generation += 1
            // Written by hand rather than with @AppStorage: that is a
            // DynamicProperty and only works inside a View.
            defaults.set(scope.folderID ?? 0, forKey: Self.defaultsKey)
        }
    }

    private let defaults: UserDefaults

    /// Starts from the folders the server last named. The server's list arrives near the
    /// end of launch, and until then every library choice read as "all": Home built the
    /// mixes from both libraries with one chosen, and never rebuilt them, because the
    /// choice itself had not changed.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.foldersKey),
           let saved = try? JSONDecoder().decode([MusicFolder].self, from: data) {
            folders = saved
            scope = Self.restored(defaults.integer(forKey: Self.defaultsKey), in: saved)
        }
    }

    /// Adopts the server's folder list, then restores the saved selection. A saved
    /// id that no longer exists on the server falls back to `.all` rather than
    /// silently filtering everything out.
    func adopt(folders: [MusicFolder]) {
        self.folders = folders
        if let data = try? JSONEncoder().encode(folders) {
            defaults.set(data, forKey: Self.foldersKey)
        }
        scope = Self.restored(defaults.integer(forKey: Self.defaultsKey), in: folders)
    }

    private static func restored(_ savedID: Int, in folders: [MusicFolder]) -> LibraryScope {
        guard savedID != 0, let match = folders.first(where: { $0.id == savedID }) else { return .all }
        return .folder(id: match.id, name: match.name)
    }

    /// The library for a folder id as stored by a picker, where -1 means all of them. An
    /// id the server no longer has means all, rather than an empty answer.
    func scope(forFolderID id: Int) -> LibraryScope {
        guard id != -1, let folder = folders.first(where: { $0.id == id }) else { return .all }
        return .folder(id: folder.id, name: folder.name)
    }

    /// Where the daily mixes come from. One answer for every caller: the playback
    /// controller used to grow a mix, and top up the shelf, from the *browsing* library,
    /// and a top-up in another library starts the day's mixes over in that library.
    var mixScope: LibraryScope {
        scope(forFolderID: defaults.object(forKey: Self.mixesKey) as? Int ?? -1)
    }

    /// A single-library server needs no control at all.
    var isSwitchable: Bool { folders.count > 1 }

    var options: [LibraryScope] {
        [.all] + folders.map { .folder(id: $0.id, name: $0.name) }
    }
}
