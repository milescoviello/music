import AVFoundation
import Foundation

/// Reads a local file's first and last seconds for Sweet Fades.
enum TrackAnalyzer {
    /// Nil for anything AVFoundation cannot open as audio. Synchronous and CPU-bound —
    /// decoding thirty seconds — so it is only ever called off the main actor.
    static func shape(of url: URL) -> TrackShape? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = file.processingFormat.sampleRate
        let length = file.length
        guard length > 0, sampleRate > 0 else { return nil }

        let span = AVAudioFramePosition(SweetFades.analysedSeconds * sampleRate)
        let outroStart = max(0, length - span)
        guard let intro = read(file, from: 0, count: min(span, length)),
              let outro = read(file, from: outroStart, count: length - outroStart)
        else { return nil }

        return TrackShape.measure(intro: intro, outro: outro, sampleRate: sampleRate)
    }

    /// Non-interleaved channels, at most two: BS.1770 weights front left and right
    /// equally, and anything past them is not what a fade is judged by.
    private static func read(
        _ file: AVAudioFile,
        from start: AVAudioFramePosition,
        count: AVAudioFramePosition
    ) -> [[Float]]? {
        guard count > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: file.processingFormat,
                  frameCapacity: AVAudioFrameCount(count)
              )
        else { return nil }

        file.framePosition = start
        do {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
        } catch {
            return nil
        }

        // The processing format is always deinterleaved Float32, so this is never nil
        // for a buffer that read successfully.
        guard let data = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let channels = min(Int(buffer.format.channelCount), 2)
        return (0..<channels).map { Array(UnsafeBufferPointer(start: data[$0], count: frames)) }
    }
}

/// The measured shapes of tracks, one small file each in Caches.
///
/// One file per track rather than one index: nothing has to be loaded at launch, a
/// purge by iOS loses nothing that cannot be measured again, and a shape is read once per
/// track per session and then held in memory.
@MainActor
final class TrackShapeStore {
    private var known: [String: TrackShape] = [:]
    /// Looked for on disk and not there, so the planner can ask on every queue change
    /// without touching the file system each time.
    private var absent: Set<String> = []
    private var measuring: Set<String> = []

    /// A track was measured. The transitions either side of it can now be planned
    /// properly instead of guessed.
    var onMeasured: ((String) -> Void)?

    func shape(for songID: String) -> TrackShape? {
        if let shape = known[songID] { return shape }
        guard !absent.contains(songID) else { return nil }

        if let data = try? Data(contentsOf: file(for: songID)),
           let shape = try? JSONDecoder().decode(TrackShape.self, from: data) {
            known[songID] = shape
            return shape
        }
        absent.insert(songID)
        return nil
    }

    /// Measures a local file, once. Cheap to call repeatedly: a known or in-progress
    /// track returns at once.
    func measure(songID: String, at url: URL) {
        guard shape(for: songID) == nil, !measuring.contains(songID) else { return }
        measuring.insert(songID)

        let destination = file(for: songID)
        Task {
            let shape = await Task.detached(priority: .utility) { () -> TrackShape? in
                guard let shape = TrackAnalyzer.shape(of: url) else { return nil }
                if let data = try? JSONEncoder().encode(shape) {
                    try? data.write(to: destination, options: .atomic)
                }
                return shape
            }.value

            measuring.remove(songID)
            guard let shape else { return }
            known[songID] = shape
            absent.remove(songID)
            onMeasured?(songID)
        }
    }

    private func file(for songID: String) -> URL {
        let safe = songID.replacingOccurrences(of: "/", with: "_")
        return Paths.trackShapes.appendingPathComponent("\(safe).json")
    }
}
