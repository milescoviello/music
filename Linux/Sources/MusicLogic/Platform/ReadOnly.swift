import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Screenshot runs (`MUSIC_READONLY=1`, set by `tools/linux-shot`): a second copy of the app,
/// on a copy of its data, that reads the server and changes nothing on it. No plays, stars,
/// ratings, queue uploads, bookmarks or playlist edits leave this process, so its outbox and
/// its restored queue can't double up on what the real app sends; and it doesn't announce
/// itself as a remote to the phone.
enum ReadOnly {
    static let isOn = ProcessInfo.processInfo.environment["MUSIC_READONLY"] == "1"

    private static let writes: Set<String> = [
        "star", "unstar", "setRating", "scrobble", "createPlaylist", "updatePlaylist",
        "deletePlaylist", "savePlayQueue", "createBookmark", "deleteBookmark",
    ]

    /// True for a request this run must not send.
    static func refuses(_ request: URLRequest) -> Bool {
        guard isOn, let url = request.url else { return false }
        let last = url.lastPathComponent
        let name = last.hasSuffix(".view") ? String(last.dropLast(5)) : last
        if writes.contains(name) { return true }
        let method = request.httpMethod ?? "GET"
        if method == "GET" || method == "HEAD" { return false }
        // Navidrome's native API signs in by POST; reading anything after needs it.
        return !url.path.hasSuffix("/auth/login")
    }
}
