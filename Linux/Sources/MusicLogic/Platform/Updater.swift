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

    /// The new build, in place of this one: started in a session of its own once this
    /// process has gone, as a copy started while this one is still quitting hands itself to
    /// it as a second window, and then both are gone (tried: a fixed 1.5 s wait was too short).
    func reopen() {
        // Where the installer put it: `$HOME`, as it uses, not the account's home directory,
        // which differs when HOME is set to something else.
        let home = ProcessInfo.processInfo.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let binary = home + "/.local/bin/music"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/setsid")
        process.arguments = ["-f", "/bin/sh", "-c", """
            for i in $(seq 1 300); do kill -0 "$0" 2>/dev/null || break; sleep 0.1; done
            exec "$1" >/dev/null 2>&1 < /dev/null
            """, String(ProcessInfo.processInfo.processIdentifier), binary]
        do {
            try process.run()
        } catch {
            state = .failed("Couldn't reopen: \(error.localizedDescription)")
            Task { await Diagnostics.shared.record("app", "update: couldn't reopen: \(error.localizedDescription)") }
            return
        }
        Task {
            await Diagnostics.shared.record("app", "update: reopening on the new build")
            if let application = Desktop.application { g_application_quit(application.cast()) }
        }
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
