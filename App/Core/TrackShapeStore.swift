import AVFoundation
import Foundation
import Observation

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

        return TrackShape.measure(intro: intro, outro: outro, sampleRate: sampleRate, power: power(of: file))
    }

    /// Mean-square power of each of `TrackShape.envelopePoints` equal slices of the whole
    /// track, for the seekbar. Read in one-second blocks, so a long track costs time but
    /// never memory. Nil if any block fails: a partial outline would draw a lie.
    private static func power(of file: AVAudioFile) -> [Double]? {
        let length = file.length
        let slices = TrackShape.envelopePoints
        guard length >= AVAudioFramePosition(slices) else { return nil }

        let block = AVAudioFrameCount(max(4_096, Int(file.processingFormat.sampleRate)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: block) else { return nil }

        var sums = [Double](repeating: 0, count: slices)
        var counts = [Int](repeating: 0, count: slices)
        file.framePosition = 0
        var position: AVAudioFramePosition = 0

        while position < length {
            do {
                try file.read(into: buffer, frameCount: min(block, AVAudioFrameCount(length - position)))
            } catch {
                return nil
            }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            let channels = min(Int(buffer.format.channelCount), 2)

            for frame in 0..<frames {
                var square: Double = 0
                for channel in 0..<channels {
                    let sample = Double(data[channel][frame])
                    square += sample * sample
                }
                let slice = min(slices - 1, Int((position + AVAudioFramePosition(frame)) * AVAudioFramePosition(slices) / length))
                sums[slice] += square
                counts[slice] += 1
            }
            position += AVAudioFramePosition(frames)
        }

        return zip(sums, counts).map { $1 > 0 ? $0 / Double($1) : 0 }
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
@Observable
final class TrackShapeStore {
    /// Observed, so the seekbar redraws when the track playing gets its outline.
    private(set) var known: [String: TrackShape] = [:]
    /// Looked for on disk and not there, so the planner can ask on every queue change
    /// without touching the file system each time.
    @ObservationIgnored private var absent: Set<String> = []
    @ObservationIgnored private var measuring: Set<String> = []
    /// Measured this session, successfully or not. A file that cannot give an outline is
    /// not decoded again on every queue change.
    @ObservationIgnored private var attempted: Set<String> = []

    /// A track was measured. The transitions either side of it can now be planned
    /// properly instead of guessed.
    @ObservationIgnored var onMeasured: ((String) -> Void)?

    /// For a view body: what is already in memory, without touching the disk — reading
    /// from disk here would write `known` while the view is being drawn. Call
    /// `shape(for:)` from a `.task` to load it.
    func loadedShape(for songID: String) -> TrackShape? {
        known[songID]
    }

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
        // Shapes measured before the seekbar outline existed are measured again, once.
        guard !attempted.contains(songID), shape(for: songID)?.envelope == nil else { return }
        attempted.insert(songID)
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
