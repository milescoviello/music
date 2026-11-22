import CGtk
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation

/// Settings > Updates: the desktop app from its newest ready-made build (the `linux-latest`
/// release, which `Linux/get.sh` installs from), with no Swift, no building and nothing to
/// type. The build here is said by the `BUILD` file the installer writes beside the data;
/// the newest by the release's notes, which carry its commit.
@MainActor
@Observable
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case updating
        /// Installed; this window still runs the old one until it is reopened.
        case updated
        case failed(String)
    }

    private(set) var state: State = .idle
    /// This build's commit and when it was made, if the installer said.
    private(set) var installed: (commit: String, built: String)?
    private(set) var newest: String?

    static let shared = Updater()

    static let release = URL(string: "https://api.github.com/repos/milescoviello/music/releases/tags/linux-latest")!
    nonisolated static let asset = "https://github.com/milescoviello/music/releases/download/linux-latest/Music-linux-x86_64.tar.gz"

    init() {
        let file = Paths.root.appendingPathComponent("BUILD")
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            let parts = text.split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if parts.count >= 2 { installed = (parts[0], parts[1]) }
        }
    }

    func check() async {
        guard state != .updating else { return }
        state = .checking
        var request = URLRequest(url: Self.release)
        request.setValue("Music", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        do {
            let (data, _) = try await URLSession.shared.fetch(request)
            let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["body"] as? String ?? ""
            guard let range = body.range(of: "[0-9a-f]{40}", options: .regularExpression) else {
                state = .failed("Couldn't read the newest build.")
                return
            }
            newest = String(body[range])
            state = newest == installed?.commit ? .upToDate : .available
        } catch {
            state = .failed("Couldn't reach GitHub to check.")
        }
    }

    /// Downloads, checks and installs the newest build, as `Linux/get.sh` does. Off the main
    /// thread: it is a download and a shell.
    func update() async {
        guard state != .updating else { return }
        state = .updating
        let result = await Task.detached(priority: .userInitiated) { () -> (Int32, String) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", Self.script, "update", Self.asset]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
            } catch {
                return (-1, error.localizedDescription)
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
        let lastLine = result.1.split(separator: "\n").last.map(String.init) ?? ""
        await Diagnostics.shared.record("app", "update: \(result.0 == 0 ? "installed \(newest?.prefix(7) ?? "?")" : "failed: \(lastLine)")")
        if result.0 == 0 {
            installed = newest.map { ($0, ISO8601DateFormatter().string(from: .now)) } ?? installed
            state = .updated
        } else {
            state = .failed(lastLine.isEmpty ? "The update didn't install." : lastLine)
        }
    }

    /// The new build, in place of this one: it starts once this has quit and let go of the
    /// single-instance name, as a second copy started now would hand itself to this one.
    func reopen() {
        let binary = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/music").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1.5; exec setsid \"$0\" >/dev/null 2>&1 < /dev/null", binary]
        try? process.run()
        if let application = Desktop.application { g_application_quit(application.cast()) }
    }

    /// `Linux/get.sh`'s steps, from the release's URL (`$1`): the build downloaded and its
    /// checksum compared, its libraries checked, then its own installer run.
    nonisolated static let script = """
    set -eu
    url=$1
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT INT TERM
    curl -fsSL "$url" -o "$work/music.tar.gz"
    curl -fsSL "$url.sha256" -o "$work/music.sha256"
    [ "$(cut -d' ' -f1 "$work/music.sha256")" = "$(sha256sum "$work/music.tar.gz" | cut -d' ' -f1)" ] \\
        || { echo "The download is damaged; nothing was installed."; exit 1; }
    tar -xzf "$work/music.tar.gz" -C "$work"
    missing=$(ldd "$work/Music/music" 2>/dev/null | sed -n 's/^[[:space:]]*\\([^ ]*\\) => not found.*/\\1/p' | tr '\\n' ' ')
    [ -z "$missing" ] || { echo "Missing libraries: $missing"; exit 1; }
    sh "$work/Music/Linux/install.sh" --prebuilt
    """
}
