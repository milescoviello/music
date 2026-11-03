import Foundation

/// Reports that could not be sent, kept on the device until they can be.
///
/// Logs are most often wanted exactly when the connection is the problem, which is when
/// Send Logs used to fail and leave a "share instead" button. Now a failed send is kept
/// here and sent, oldest first, the next time the outbox is flushed: on launch, on coming
/// back to the app, and when the network changes.
enum UnsentLogs {
    static var directory: URL { Paths.root.appendingPathComponent("unsent-logs", isDirectory: true) }

    static func keep(_ text: String, at date: Date = .now) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(Int(date.timeIntervalSince1970 * 1000)).txt"
        try? Data(text.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    static var waiting: [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static var count: Int { waiting.count }
}

extension AppState {
    /// Sends `report`, or keeps it to send later. Returns the name the server filed it
    /// under, or nil when it was kept.
    func sendOrKeepLogs(_ report: LogReport) async throws -> String? {
        do {
            return try await sendLogs(report)
        } catch {
            UnsentLogs.keep(report.text())
            await Diagnostics.shared.record("logs", "could not send (\(LogReport.failure(error))): kept to send later")
            throw error
        }
    }

    /// The kept reports, oldest first, each marked as late. Stops at the first that fails:
    /// the rest would only fail the same way.
    func flushUnsentLogs() async {
        for file in UnsentLogs.waiting {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let late = "Kept on the device and sent later, at \(ISO8601DateFormatter().string(from: Date())).\n\n" + text
            do {
                let name = try await SonicClient(configuration: sonic.configuration).sendLogs(late, source: LogReport.source)
                try? FileManager.default.removeItem(at: file)
                await Diagnostics.shared.record("logs", "sent a kept report: \(name)")
            } catch {
                return
            }
        }
    }
}
