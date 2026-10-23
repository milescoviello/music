#if canImport(CFFmpeg)
import Foundation
import Testing

@testable import MusicLogic

/// A track whose server does not answer is held, not skipped: the rest of the queue comes
/// from the same server and would fail the same way, and skipping through it once left the
/// player "playing" silence. A track that cannot be decoded is still skipped.
///
/// Linux only: this is the desktop's own decoder and mixer.
struct UnreachableTrackTests {
    private let rate = 48_000

    /// Nothing listens on the discard port, so the connection is refused at once.
    private let refused = URL(string: "http://127.0.0.1:9/rest/stream.view")!
    private let missing = URL(fileURLWithPath: "/nonexistent/track.flac")

    private func source(_ id: String, _ url: URL) -> TrackSource {
        let location = MediaLocation(url: url, mimeType: nil, isLocal: url.isFileURL)
        return TrackSource(song: Song(id: id, title: id), location: location, rate: rate, chain: nil)
    }

    /// FFmpeg's reconnect options can retry a refused open for a few seconds.
    private func failed(_ source: TrackSource) async -> TrackSource {
        source.start()
        for _ in 0..<600 where !source.didFail {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return source
    }

    private func render(_ mixer: Mixer, buffers: Int) {
        let frames = 1_024
        let output = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        defer { output.deallocate() }
        for _ in 0..<buffers {
            mixer.render(into: output, frames: frames)
        }
    }

    @Test func aRefusedStreamIsUnreachable() async {
        let track = await failed(source("a", refused))
        #expect(track.didFail)
        #expect(track.isUnreachable)
    }

    @Test func aMissingFileIsNotUnreachable() async {
        let track = await failed(source("a", missing))
        #expect(track.didFail)
        #expect(!track.isUnreachable)
    }

    @Test func theMixerHoldsAnUnreachableTrack() async {
        let held = await failed(source("a", refused))
        let next = source("b", refused)
        let mixer = Mixer(rate: rate)
        mixer.active = Voice(sources: [held, next])
        render(mixer, buffers: 8)
        #expect(mixer.active?.sources.first === held)
        next.cancel()
    }

    @Test func theMixerSkipsATrackThatCannotBeDecoded() async {
        let broken = await failed(source("a", missing))
        let next = source("b", missing)
        let mixer = Mixer(rate: rate)
        mixer.active = Voice(sources: [broken, next])
        render(mixer, buffers: 8)
        #expect(mixer.active?.sources.first === next)
    }
}
#endif
