import Foundation
import Testing

@testable import MusicLogic

/// The log is appended to, line by line, and must come back whole after a launch: it is
/// what a bug is looked into with.
struct DiagnosticsTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func lines(in folder: URL) throws -> [String] {
        try String(contentsOf: folder.appendingPathComponent("diagnostics.jsonl"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    @Test func whatIsRecordedIsThereAfterALaunch() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = Diagnostics(directory: folder)
        await first.record("network", "now wifi")
        await first.record("cache", "failed")

        let relaunched = await Diagnostics(directory: folder).recent()
        #expect(relaunched.map(\.message) == ["failed", "now wifi"])
        #expect(try lines(in: folder).count == 2)
    }

    @Test func theFileIsCutBackToTheNewest() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = Diagnostics(directory: folder, limit: 3, slack: 2)
        for index in 1...10 { await log.record("test", "\(index)") }

        #expect(await log.recent().map(\.message) == ["10", "9", "8"])
        #expect(try lines(in: folder).count <= 5)
        let relaunched = await Diagnostics(directory: folder, limit: 3, slack: 2).recent()
        #expect(relaunched.map(\.message) == ["10", "9", "8"])
    }

    @Test func theOldLogIsCarriedOver() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = [
            Diagnostics.Line(at: Date(timeIntervalSince1970: 200), area: "cache", message: "newer"),
            Diagnostics.Line(at: Date(timeIntervalSince1970: 100), area: "cache", message: "older"),
        ]
        try JSONEncoder().encode(old).write(to: folder.appendingPathComponent("diagnostics.json"))

        let log = Diagnostics(directory: folder)
        await log.record("app", "launched")
        #expect(await log.recent().map(\.message) == ["launched", "newer", "older"])
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("diagnostics.json").path))
        #expect(await Diagnostics(directory: folder).recent().map(\.message) == ["launched", "newer", "older"])
    }

    @Test func clearingEmptiesTheFileToo() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = Diagnostics(directory: folder)
        await log.record("test", "one")
        await log.clear()
        await log.record("test", "two")
        #expect(await Diagnostics(directory: folder).recent().map(\.message) == ["two"])
    }

    @Test func noTokenInAURL() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = Diagnostics(directory: folder)
        await log.record("stream", "http://server/rest/stream.view?u=miles&t=secret&s=salt failed")
        #expect(await log.recent().first?.message == "http://server/rest/stream.view?… failed")
        #expect(try !lines(in: folder).joined().contains("secret"))
    }

    @Test func howLong() {
        #expect(Diagnostics.duration(0.42) == "0.4s")
        #expect(Diagnostics.duration(42) == "42s")
        #expect(Diagnostics.duration(130) == "2m10s")
        #expect(Diagnostics.duration(936) == "15m36s")
        #expect(Diagnostics.duration(3780) == "1h03m")
        #expect(Diagnostics.duration(-1) == "?")
    }

    @Test func anErrorWithItsCode() {
        let timeout = NSError(domain: NSURLErrorDomain, code: -1001, userInfo: [NSLocalizedDescriptionKey: "The request timed out."])
        #expect(Diagnostics.describe(timeout) == "The request timed out. (NSURLErrorDomain -1001)")
    }
}
