import Foundation
import Testing

@testable import MusicLogic

/// Send Logs: the report is what gets read on the server when a bug is looked into, so
/// its shape is the contract.
struct LogReportTests {
    private let pacific = TimeZone(identifier: "America/Los_Angeles")!

    /// 2026-11-02 18:14:03 UTC: 10:14:03 in Pacific, the day after the clocks went back.
    private func report(note: String = "", sections: [LogReport.Section] = [], log: String = "") -> LogReport {
        LogReport(
            sentAt: Date(timeIntervalSince1970: 1_793_643_243),
            app: "0.1.0 · build 412 · 2d23852",
            system: "iOS 26.1",
            note: note,
            sections: sections,
            log: log
        )
    }

    @Test func theReportReadsTopToBottom() {
        let text = report(
            note: "The second play didn't count",
            sections: [.init(title: "Playback", rows: [.init(label: "Song", value: "A — B (s1)")])],
            log: "11-02 10:01:00  [scrobble]  timed out"
        ).text(in: pacific)
        #expect(text == """
        Music logs
        Sent: 2026-11-02 10:14:03 PST (2026-11-02T18:14:03Z)
        App: 0.1.0 · build 412 · 2d23852
        System: iOS 26.1

        What went wrong:
          The second play didn't count

        Playback:
          Song: A — B (s1)

        Log, oldest first:
        11-02 10:01:00  [scrobble]  timed out

        """)
    }

    @Test func whatIsEmptyIsLeftOut() {
        let text = report(note: "  \n ", sections: [.init(title: "Sync", rows: [])]).text(in: pacific)
        #expect(!text.contains("What went wrong"))
        #expect(!text.contains("Sync:"))
        #expect(text.hasSuffix("Log, oldest first:\n  Nothing logged yet.\n"))
    }

    @Test func aNoteOfSeveralLinesStaysTogether() {
        let text = report(note: "Skipped at 2:30\nthen stopped").text(in: pacific)
        #expect(text.contains("What went wrong:\n  Skipped at 2:30\n  then stopped\n"))
    }

    @Test func positions() {
        #expect(LogReport.clock(0) == "0:00")
        #expect(LogReport.clock(65.9) == "1:05")
        #expect(LogReport.clock(3723) == "1:02:03")
        #expect(LogReport.clock(.nan) == "?")
        #expect(LogReport.clock(-1) == "?")
    }

    @Test func whyItDidNotArriveIsWords() {
        #expect(LogReport.failure(SonicError.status(404)).contains("needs updating"))
        #expect(LogReport.failure(SonicError.status(500)) == "The sonic service answered 500.")
    }

    @Test func theReportGoesUpAsItIs() throws {
        let client = SonicClient(configuration: .init(baseURL: URL(string: "http://192.168.1.148:8650")!, token: "abc"))
        let request = try #require(client.logsRequest("Music logs\nüñí", source: "linux-gentoo"))
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "http://192.168.1.148:8650/v1/logs")
        #expect(request.httpBody == Data("Music logs\nüñí".utf8))
        #expect(request.value(forHTTPHeaderField: "X-Log-Source") == "linux-gentoo")
        #expect(request.value(forHTTPHeaderField: "X-Sonic-Token") == "abc")

        let open = try #require(SonicClient(configuration: .default).logsRequest("x", source: "ios"))
        #expect(open.value(forHTTPHeaderField: "X-Sonic-Token") == nil)
    }
}
