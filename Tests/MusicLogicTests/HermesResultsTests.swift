import Foundation
import Testing

@testable import MusicLogic

/// The agent writes these files, which means an LLM is choosing the keys. Decoding has to
/// tolerate extra fields, missing optional fields, and snake_case — and a missing *file*
/// must never be confused with a failure. All of that is cheaper to pin here than to
/// discover on the phone.
struct HermesResultsTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        // Deliberately a bare decoder, matching `HermesClient`: the types carry their own
        // keys, so this pins the literal wire contract the agent's prompt has to produce.
        return try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func vibeResultDecodesSnakeCase() throws {
        let result = try decode(VibeResult.self, """
        {"status":"ok","playlist_id":"abc","playlist_name":"Late Night Drive",
         "track_count":25,"note":"Slow, warm, mostly 2010s."}
        """)
        #expect(result.isOK)
        #expect(result.playlistID == "abc")
        #expect(result.trackCount == 25)
    }

    /// An agent adding a field it thought was helpful must not break the feature.
    @Test func unknownKeysAreIgnored() throws {
        let result = try decode(VibeResult.self, """
        {"status":"ok","playlist_id":"abc","confidence":0.8,"reasoning":"…"}
        """)
        #expect(result.isOK)
        #expect(result.playlistID == "abc")
    }

    @Test func errorStatusCarriesItsMessage() throws {
        let result = try decode(VibeResult.self, """
        {"status":"error","message":"Nothing in the library fits that."}
        """)
        #expect(result.isOK == false)
        #expect(result.failureText == "Nothing in the library fits that.")
    }

    @Test func errorWithNoMessageStillReadsSensibly() throws {
        let result = try decode(VibeResult.self, #"{"status":"error"}"#)
        #expect(result.failureText.isEmpty == false)
    }

    /// Finding nothing is a real answer, not a failure — the library genuinely may have no
    /// matching lyric on file, and only 6.5% of tracks have lyrics at all.
    @Test func emptyLyricMatchesIsSuccessNotFailure() throws {
        let result = try decode(LyricSearchResult.self, #"{"status":"ok","matches":[]}"#)
        #expect(result.isOK)
        #expect(result.found.isEmpty)
    }

    @Test func missingMatchesKeyIsTreatedAsEmpty() throws {
        let result = try decode(LyricSearchResult.self, #"{"status":"ok"}"#)
        #expect(result.found.isEmpty)
    }

    @Test func lyricMatchKeepsItsTimestamp() throws {
        let result = try decode(LyricSearchResult.self, """
        {"status":"ok","matches":[
          {"song_id":"s1","title":"Paper Moons","artist":"The Lanterns","line":"walkin' home slow","at_ms":84200}
        ]}
        """)
        #expect(result.found.first?.atMs == 84_200)
        #expect(result.found.first?.songID == "s1")
    }

    @Test func noteSplitsIntoParagraphs() throws {
        let note = try decode(HermesNote.self, """
        {"status":"ok","kind":"album","name":"L>O>W>L>A>N>D",
         "text":"One.\\n\\nTwo.\\n\\n\\nThree.","sources":["https://example.com"]}
        """)
        #expect(note.paragraphs == ["One.", "Two.", "Three."])
        #expect(note.sources?.count == 1)
    }

    @Test func healthReportDecodesDuplicateGroups() throws {
        let report = try decode(HealthReport.self, """
        {"status":"ok","total_tracks":18250,"missing_year":90,"missing_artwork":1500,
         "duplicate_groups":[
           {"title":"Paper Moons","artist":"Glass Harbor","copies":[
             {"song_id":"a","path":"Music/x.flac","library":"Music"},
             {"song_id":"b","path":"My Music/x.flac","library":"My Music"}]}]}
        """)
        #expect(report.totalTracks == 18_250)
        #expect(report.duplicateGroups?.first?.copies.count == 2)
        // Stable id so a refreshed list does not reshuffle.
        #expect(report.duplicateGroups?.first?.id == "Glass Harbor|Paper Moons")
    }
}

/// The playlist name is dictated to Hermes rather than chosen by it, because it doubles as
/// the fallback signal when the results file never lands.
struct VibeTitleTests {
    @Test func titleCasesTheVibe() {
        #expect(VibeTitle.sanitised("late night drive") == "Late Night Drive")
    }

    @Test func leavesAcronymsAlone() {
        // "DJ MOTH" must not become "Dj Moth".
        #expect(VibeTitle.sanitised("DJ MOTH beats") == "DJ MOTH Beats")
    }

    @Test func collapsesWhitespaceAndNewlines() {
        #expect(VibeTitle.sanitised("  rainy \n\n day  ") == "Rainy Day")
    }

    @Test func emptyInputStillYieldsAName() {
        #expect(VibeTitle.sanitised("   ").isEmpty == false)
    }

    @Test func longVibesAreTrimmedToSixWords() {
        let title = VibeTitle.sanitised("one two three four five six seven eight")
        #expect(title.split(separator: " ").count == 6)
    }

    @Test func uniqueSuffixesOnlyOnCollision() {
        let id = UUID()
        #expect(VibeTitle.unique("Late Night Drive", existing: ["Other"], requestID: id) == "Late Night Drive")

        let collided = VibeTitle.unique("Late Night Drive", existing: ["late night drive"], requestID: id)
        #expect(collided != "Late Night Drive")
        #expect(collided.hasPrefix("Late Night Drive · "))
    }
}
