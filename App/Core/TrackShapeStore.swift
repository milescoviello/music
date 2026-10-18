import AVFoundation
import Foundation
import Observation

/// Reads a local file's loudness, start to end, for Sweet Fades and the seekbar.
enum TrackAnalyzer {
    /// Nil for anything AVFoundation cannot open as audio, or that fails part way: a
    /// partial outline would draw a lie. Synchronous and CPU-bound — decoding the whole
    /// track — so it is only ever called off the main actor.
    ///
    /// One pass, in one-second blocks, so a long track costs time but never memory. At
    /// most two channels: BS.1770 weights front left and right equally, and anything past
    /// them is not what a fade or a seekbar is judged by.
    static func shape(of url: URL) -> TrackShape? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let length = file.length
        let channels = min(Int(format.channelCount), 2)
        let block = AVAudioFrameCount(max(4_096, Int(format.sampleRate)))
        guard length > 0,
              var meter = MomentaryLoudness(sampleRate: format.sampleRate, channels: channels),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block)
        else { return nil }

        file.framePosition = 0
        var position: AVAudioFramePosition = 0
        while position < length {
            do {
                try file.read(into: buffer, frameCount: min(block, AVAudioFrameCount(length - position)))
            } catch {
                return nil
            }
            // The processing format is always deinterleaved Float32, so this is never nil
            // for a buffer that read successfully.
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            meter.add((0..<channels).map { Array(UnsafeBufferPointer(start: data[$0], count: frames)) })
            position += AVAudioFramePosition(frames)
        }

        return TrackShape.measure(momentary: meter.finish())
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
        // Shapes measured before the seekbar's levels existed are measured again, once.
        guard !attempted.contains(songID), shape(for: songID)?.levels == nil else { return }
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
