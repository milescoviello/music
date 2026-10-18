import Foundation

/// Reads a local file's loudness, start to end, for Sweet Fades and the seekbar — the
/// phone's `TrackAnalyzer`, decoding with FFmpeg instead of `AVAudioFile`.
///
/// Nil for anything that cannot be opened as audio or fails part way: a partial outline
/// would draw a lie. Synchronous and CPU-bound, so only ever called off the main actor.
/// One pass, a second at a time, so a long track costs time but never memory.
enum TrackAnalyzer {
    private static let rate: Int32 = 48_000

    static func shape(of url: URL) -> TrackShape? {
        let decoder = AudioDecoder(url: url, outputRate: rate)
        do { try decoder.open() } catch { return nil }
        defer { decoder.close() }

        // BS.1770 weights front left and right equally; a mono file is one channel, not
        // the same channel twice.
        let channels = decoder.sourceChannels
        guard var meter = MomentaryLoudness(sampleRate: Double(rate), channels: channels) else { return nil }

        let block = Int(rate)
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(block * 2)
        right.reserveCapacity(block * 2)

        func flush() {
            guard !left.isEmpty else { return }
            meter.add(channels == 1 ? [left] : [left, right])
            left.removeAll(keepingCapacity: true)
            right.removeAll(keepingCapacity: true)
        }

        do {
            while let chunk = try decoder.next() {
                left.append(contentsOf: UnsafeBufferPointer(start: chunk.left, count: chunk.count))
                right.append(contentsOf: UnsafeBufferPointer(start: chunk.right, count: chunk.count))
                if left.count >= block { flush() }
            }
        } catch {
            return nil
        }
        flush()
        return TrackShape.measure(momentary: meter.finish())
    }
}
