import Foundation
import Testing
@testable import MusicLogic

/// The music videos' side of the sonic service: links pasted into Change Video, the
/// addresses a player opens, and the shapes the service answers in.
struct VideoClientTests {
    private let client = VideoClient(configuration: .init(baseURL: URL(string: "http://sonic.local:8650")!))

    @Test func everyKindOfYouTubeLinkGivesItsVideo() {
        let id = "AbCdEfGhIj0"
        for link in [
            "https://www.youtube.com/watch?v=\(id)",
            "https://www.youtube.com/watch?v=\(id)&list=PLx&t=42s",
            "https://m.youtube.com/watch?feature=share&v=\(id)",
            "https://music.youtube.com/watch?v=\(id)",
            "https://youtu.be/\(id)?si=abc",
            "youtu.be/\(id)",
            "https://www.youtube.com/shorts/\(id)",
            "https://www.youtube.com/embed/\(id)",
            "https://www.youtube-nocookie.com/embed/\(id)",
            "  \(id)  ",
        ] {
            #expect(VideoClient.videoID(fromLink: link) == id, "\(link)")
        }
    }

    @Test func wordsAndOtherSitesAreNotVideos() {
        for text in ["glass harbor low tide", "https://example.com/watch?v=AbCdEfGhIj0", "AbCdEfGhIj", "AbCdEfGhIj0x",
                     "https://youtu.be/", "https://www.youtube.com/channel/UCabcdefghij", ""] {
            #expect(VideoClient.videoID(fromLink: text) == nil, "\(text)")
        }
    }

    @Test func playerAddressesAreTheServicesOwn() {
        #expect(client.masterURL(videoID: "AbCdEfGhIj0")?.absoluteString
            == "http://sonic.local:8650/v1/video/AbCdEfGhIj0/master.m3u8")
        #expect(client.mediaURL("v1/video/AbCdEfGhIj0/137.mp4")?.absoluteString
            == "http://sonic.local:8650/v1/video/AbCdEfGhIj0/137.mp4")
    }

    @Test func theTokenRidesOnAddressesAPlayerFetches() {
        let guarded = VideoClient(configuration: .init(baseURL: URL(string: "http://sonic.local:8650")!, token: "s3cret"))
        #expect(guarded.masterURL(videoID: "AbCdEfGhIj0")?.absoluteString
            == "http://sonic.local:8650/v1/video/AbCdEfGhIj0/master.m3u8?token=s3cret")
        // The service names its paths with the token already on; it is not doubled.
        #expect(guarded.mediaURL("v1/video/AbCdEfGhIj0/251.webm?token=s3cret")?.absoluteString
            == "http://sonic.local:8650/v1/video/AbCdEfGhIj0/251.webm?token=s3cret")
    }

    @Test func searchQueriesKeepTheirPlus() {
        #expect(client.url("v1/video/search", ["q": "1+1"])?.absoluteString.contains("q=1%2B1") == true)
    }

    @Test func decodesTheServicesAnswers() throws {
        let match = try JSONDecoder().decode(VideoClient.Match.self, from: Data(#"""
        {"video":{"id":"AbCdEfGhIj0","title":"Glass Harbor - Low Tide","channel":"Glass Harbor","duration":241.0},
         "manual":true,"offset":0.0}
        """#.utf8))
        #expect(match.video?.channel == "Glass Harbor")
        #expect(match.manual)

        let none = try JSONDecoder().decode(VideoClient.Match.self, from: Data(#"{"video":null,"manual":false,"offset":0.0}"#.utf8))
        #expect(none.video == nil)

        let streams = try JSONDecoder().decode(VideoClient.Streams.self, from: Data(#"""
        {"id":"AbCdEfGhIj0","title":"Low Tide","channel":"Glass Harbor","duration":241.0,"width":1920,"height":1080,
         "video":"v1/video/AbCdEfGhIj0/137.mp4","audio":"v1/video/AbCdEfGhIj0/251.webm","audioCodec":"opus"}
        """#.utf8))
        #expect(streams.height == 1080)
        #expect(streams.audioCodec == "opus")
    }

    @Test func aSearchResultCarriesTheServicesGuess() throws {
        let video = try JSONDecoder().decode(VideoClient.Video.self, from: Data(#"""
        {"id":"AbCdEfGhIj0","title":"Glass Harbor - Low Tide (Official Video)","channel":"GlassHarborVEVO",
         "duration":3725,"verified":true,"views":1200000,"artist":"Glass Harbor","song":"Low Tide"}
        """#.utf8))
        #expect(video.artist == "Glass Harbor")
        #expect(video.song == "Low Tide")
        #expect(video.durationText == "1:02:05")
        #expect(video.subtitle == "GlassHarborVEVO · 1:02:05")
        #expect(VideoClient.Video(id: "x", title: "t", channel: "", duration: 61).subtitle == "1:01")
    }
}
