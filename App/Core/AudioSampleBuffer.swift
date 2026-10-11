import Foundation

/// A fixed ring buffer that the audio thread can write into safely.
///
/// The constraints here are not stylistic. The producer — `MTAudioProcessingTap`'s
/// process callback — runs on a **real-time audio thread**, where allocating, locking, or
/// hopping to an actor causes dropouts or worse. So:
///
/// - the storage is allocated once, up front, and never grows
/// - `write` does one `memcpy` and one integer update, nothing else
/// - there is no lock anywhere, in either direction
///
/// The consequence is that a `snapshot` taken while a write is in flight can contain a
/// seam — a few samples from the previous revolution of the ring. For a spectrum
/// display that is invisible, and it is the right trade: a torn frame of a visualiser
/// costs nothing, whereas blocking the audio thread costs the music.
///
/// `@unchecked Sendable` states that deliberately, rather than pretending the races
/// away with a lock that must not exist.
final class AudioSampleBuffer: @unchecked Sendable {
    /// A power of two, because the FFT needs one and this way no copy has to resize.
    ///
    /// 2048 rather than 4096: at 48 kHz that is a 43 ms window instead of 85 ms, and the
    /// longer one visibly smeared transients — a snare arrived as a slow swell. Frequency
    /// resolution suffers, but for 32 log-spaced bars there is resolution to spare.
    static let capacity = 2048

    private let storage: UnsafeMutablePointer<Float>
    /// Monotonic write cursor. Wraps by masking, so no modulo on the audio thread.
    private var writeIndex = 0
    /// Set by the producer, read by the UI to tell "silent" from "not running".
    private(set) var isReceiving = false

    /// Written once by the producer before rendering starts.
    ///
    /// The analyser used to assume 44.1 kHz. The hardware usually runs at 48, and this
    /// library has 96 kHz files, so every band was mapped to the wrong frequency — the
    /// bars were showing the wrong part of the spectrum, consistently, by up to an
    /// octave.
    var sampleRate: Double = 48_000

    init() {
        storage = .allocate(capacity: Self.capacity)
        storage.initialize(repeating: 0, count: Self.capacity)
    }

    deinit {
        storage.deinitialize(count: Self.capacity)
        storage.deallocate()
    }

    /// Called from the audio thread. Mono or one channel of many — a single channel is
    /// plenty for a spectrum, and summing channels here would cost time on the wrong
    /// thread.
    func write(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        isReceiving = true

        let capacity = Self.capacity
        // Only the newest `capacity` samples can survive, so drop any excess rather
        // than wrapping over ourselves twice.
        let usable = min(count, capacity)
        let source = samples + (count - usable)

        let start = writeIndex & (capacity - 1)
        let firstChunk = min(usable, capacity - start)

        (storage + start).update(from: source, count: firstChunk)
        if firstChunk < usable {
            storage.update(from: source + firstChunk, count: usable - firstChunk)
        }

        writeIndex = writeIndex &+ usable
    }

    /// Called from the main actor. Copies the whole ring, oldest first.
    func snapshot(into destination: inout [Float]) {
        precondition(destination.count == Self.capacity)

        let capacity = Self.capacity
        let start = writeIndex & (capacity - 1)

        destination.withUnsafeMutableBufferPointer { out in
            guard let base = out.baseAddress else { return }
            let tail = capacity - start
            base.update(from: storage + start, count: tail)
            (base + tail).update(from: storage, count: start)
        }
    }

    /// Marks the producer as gone, so the display can settle to flat rather than
    /// freezing on the last frame it saw.
    func markStopped() {
        isReceiving = false
    }

    func clear() {
        storage.update(repeating: 0, count: Self.capacity)
        writeIndex = 0
        isReceiving = false
    }
}
