import Foundation

/// One track on its way to the speakers: a decoding thread filling a ring of samples, and
/// the render thread taking them out.
///
/// The ring is what makes a stream play through a stall and what makes a gapless
/// boundary gapless: the next track has seconds decoded and waiting before the current
/// one runs out. Network and decoding happen on this track's own thread and never on the
/// render thread, which only copies.
///
/// Locked rather than lock-free. The render thread here is PulseAudio's mainloop thread,
/// not a CoreAudio real-time one; the lock is held for a `memcpy` on either side and
/// never across a read from the network, so it is never waited on for long.
final class TrackSource: @unchecked Sendable {
    let song: Song
    let location: MediaLocation
    let rate: Int
    /// This track's processing: its own ReplayGain, the shared EQ and limiter.
    let chain: DSPChain?

    private let lock = NSCondition()
    private let capacity: Int
    private let ringLeft: UnsafeMutablePointer<Float>
    private let ringRight: UnsafeMutablePointer<Float>
    private var readIndex: Int64 = 0
    private var writeIndex: Int64 = 0
    /// Bumped by a seek, so a chunk decoded before it is never written after it.
    private var generation = 0
    private var decoderAtEnd = false
    private var failed = false
    /// Set with `failed` when the server did not answer, rather than the bytes not
    /// decoding. Such a track is held where it ran dry instead of being skipped.
    private var unreachable = false
    private var opened = false
    private var started = false
    private var cancelled = false
    private var pendingSeek: Double?
    /// The track position at `baseIndex`, so a position is the base plus what was read.
    private var basePosition: Double = 0
    private var baseIndex: Int64 = 0
    private var decodedDuration: Double?
    private var decoder: AudioDecoder?
    /// Set by a seek; the render thread drops its stretcher and fades the new audio in.
    private var restarted = false
    /// What the stretcher is holding, in seconds of output, published by the render
    /// thread so a position can be read from any thread.
    private var stretchLatency: Double = 0

    // Render thread only.
    private var stretcher: Stretcher?
    private var stretchFailed = false
    private var scratchLeft: UnsafeMutablePointer<Float>
    private var scratchRight: UnsafeMutablePointer<Float>
    private let scratchCapacity = 8_192
    private let channelPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    /// Frames left of a short fade-in after a seek, so the jump is not a click.
    private var declick = 0
    private static let declickFrames = 240

    init(song: Song, location: MediaLocation, rate: Int, chain: DSPChain?) {
        self.song = song
        self.location = location
        self.rate = rate
        self.chain = chain
        capacity = rate * 12
        ringLeft = .allocate(capacity: capacity)
        ringRight = .allocate(capacity: capacity)
        scratchLeft = .allocate(capacity: scratchCapacity)
        scratchRight = .allocate(capacity: scratchCapacity)
        channelPointers = .allocate(capacity: 2)
        channelPointers.initialize(repeating: scratchLeft, count: 2)
        chain?.prepare(sampleRate: Double(rate), channels: 2)
    }

    deinit {
        ringLeft.deallocate()
        ringRight.deallocate()
        scratchLeft.deallocate()
        scratchRight.deallocate()
        channelPointers.deallocate()
    }

    // MARK: - Control (any thread)

    /// Starts decoding. Idempotent; a source is made well before it is needed and started
    /// only when it is near, so a long queue is not a pile of open connections.
    func start() {
        lock.lock()
        guard !started, !cancelled else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        let thread = Thread { [self] in run() }
        thread.name = "decode \(song.title)"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    var isStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    /// Stops decoding for good. The thread finishes on its own and releases this object.
    func cancel() {
        lock.lock()
        cancelled = true
        let decoder = decoder
        lock.broadcast()
        lock.unlock()
        decoder?.cancel()
    }

    /// Jumps to a time. Whatever was decoded is dropped, and the position reads as the
    /// target at once while the decoder catches up.
    func seek(to seconds: Double) {
        lock.lock()
        generation += 1
        pendingSeek = max(0, seconds)
        readIndex = writeIndex
        basePosition = max(0, seconds)
        baseIndex = writeIndex
        decoderAtEnd = false
        restarted = true
        lock.broadcast()
        lock.unlock()
    }

    /// Seconds into the track of the next sample the render thread will take, less what
    /// the stretcher is still holding.
    var position: Double {
        lock.lock()
        defer { lock.unlock() }
        let raw = basePosition + Double(readIndex - baseIndex) / Double(rate)
        return max(basePosition, raw - stretchLatency)
    }

    /// The real length once the file is open; the server's until then.
    var duration: Double {
        lock.lock()
        defer { lock.unlock() }
        return decodedDuration ?? Double(song.duration ?? 0)
    }

    /// Whether the decoder has said how long the track is, for checks that must not run
    /// on the server's figure — a beat-matched fade's.
    var knowsDuration: Bool {
        lock.lock()
        defer { lock.unlock() }
        return decodedDuration != nil
    }

    /// Open, with half a second waiting, or already finished.
    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failed || decoderAtEnd || (opened && writeIndex - readIndex >= Int64(rate / 2))
    }

    var bufferedSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(writeIndex - readIndex) / Double(rate)
    }

    var didFail: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }

    /// Failed because the server did not answer: worth trying again, not skipping.
    var isUnreachable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return unreachable
    }

    // MARK: - Decoding thread

    private func run() {
        var decoder = AudioDecoder(url: location.url, outputRate: Int32(rate))
        if !open(decoder) { return }

        while true {
            lock.lock()
            if cancelled {
                lock.unlock()
                break
            }
            if let target = pendingSeek {
                pendingSeek = nil
                let current = generation
                lock.unlock()
                if !decoder.seek(to: target) {
                    // Not seekable — a transcode sent with no length. Opened again and
                    // decoded forward to the target, which is slow but right.
                    decoder.close()
                    decoder = AudioDecoder(url: location.url, outputRate: Int32(rate))
                    if !open(decoder) { return }
                    decoder.skipForward(to: target)
                }
                lock.lock()
                if current == generation { decoderAtEnd = false }
                lock.unlock()
                continue
            }
            // Full, or finished: wait for room, a seek, or the end.
            while !cancelled, pendingSeek == nil,
                  decoderAtEnd || Int64(capacity) - (writeIndex - readIndex) < 4_096 {
                lock.wait()
            }
            if cancelled || pendingSeek != nil {
                lock.unlock()
                continue
            }
            let current = generation
            lock.unlock()

            let chunk: AudioDecoder.Chunk?
            var lostServer = false
            do {
                chunk = try decoder.next()
            } catch {
                record("read failed part way: \(error)")
                chunk = nil
                lostServer = (error as? AudioDecoder.Failure)?.isUnreachable == true
            }

            lock.lock()
            guard current == generation else {
                lock.unlock()
                continue
            }
            if lostServer, !cancelled {
                // What was decoded still plays; the track then waits where it ran dry.
                failed = true
                unreachable = true
            }
            guard let chunk else {
                decoderAtEnd = true
                lock.broadcast()
                lock.unlock()
                continue
            }
            write(chunk, generation: current)
            lock.unlock()
        }
        decoder.close()
    }

    private func open(_ decoder: AudioDecoder) -> Bool {
        lock.lock()
        self.decoder = decoder
        let stop = cancelled
        lock.unlock()
        if stop { return false }

        do {
            try decoder.open()
        } catch {
            lock.lock()
            failed = true
            unreachable = (error as? AudioDecoder.Failure)?.isUnreachable == true
            decoderAtEnd = true
            let wasCancelled = cancelled
            lock.broadcast()
            lock.unlock()
            if !wasCancelled { record("could not open: \(error)") }
            return false
        }
        lock.lock()
        decodedDuration = decoder.duration
        opened = true
        lock.unlock()
        return true
    }

    /// Copies a chunk in, waiting for room as the render thread drains the ring. Called
    /// and returns with the lock held.
    private func write(_ chunk: AudioDecoder.Chunk, generation current: Int) {
        var offset = 0
        while offset < chunk.count {
            while !cancelled, current == generation, Int64(capacity) - (writeIndex - readIndex) == 0 {
                lock.wait()
            }
            guard !cancelled, current == generation else { return }
            let free = capacity - Int(writeIndex - readIndex)
            let start = Int(writeIndex % Int64(capacity))
            let count = min(chunk.count - offset, free, capacity - start)
            (ringLeft + start).update(from: chunk.left + offset, count: count)
            (ringRight + start).update(from: chunk.right + offset, count: count)
            writeIndex += Int64(count)
            offset += count
        }
    }

    private func record(_ message: String) {
        let title = song.title
        Task { await Diagnostics.shared.record("playback", "\(title): \(message)") }
    }

    // MARK: - Render thread

    /// Copies up to `count` frames out of the ring.
    private func readRing(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, count: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        var copied = 0
        while copied < count, readIndex < writeIndex {
            let start = Int(readIndex % Int64(capacity))
            let run = min(count - copied, Int(writeIndex - readIndex), capacity - start)
            (left + copied).update(from: ringLeft + start, count: run)
            (right + copied).update(from: ringRight + start, count: run)
            readIndex += Int64(run)
            copied += run
        }
        if copied > 0 { lock.broadcast() }
        return copied
    }

    /// True once every sample has been taken: the decoder finished or failed, the ring is
    /// empty, and nothing is left inside the stretcher.
    var isExhausted: Bool {
        lock.lock()
        let drained = (decoderAtEnd || failed) && readIndex == writeIndex && pendingSeek == nil
        lock.unlock()
        guard drained else { return false }
        return stretcher.map(\.isFinished) ?? true
    }

    /// Up to `count` processed frames at `tempo`, written over the two buffers. Fewer means
    /// the ring ran dry — a stall, or the end.
    func pull(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, count: Int, tempo: Double) -> Int {
        lock.lock()
        if restarted {
            restarted = false
            stretcher = nil
            stretchLatency = 0
            declick = Self.declickFrames
        }
        lock.unlock()

        if stretcher == nil, abs(tempo - 1) > 0.0001, !stretchFailed {
            stretcher = Stretcher(rate: rate, tempo: tempo)
            stretchFailed = stretcher == nil
        }

        let produced: Int
        if let stretcher {
            stretcher.setTempo(tempo)
            produced = stretch(stretcher, left, right, count: count)
            let latency = stretcher.latencySeconds * tempo
            lock.lock()
            stretchLatency = latency
            lock.unlock()
        } else {
            produced = readRing(left, right, count: count)
        }

        if produced > 0 {
            if let chain {
                channelPointers[0] = left
                channelPointers[1] = right
                chain.process(UnsafeMutableBufferPointer(start: channelPointers, count: 2), frames: produced)
            }
            if declick > 0 {
                let frames = min(declick, produced)
                for index in 0..<frames {
                    let gain = Float(Self.declickFrames - declick + index) / Float(Self.declickFrames)
                    left[index] *= gain
                    right[index] *= gain
                }
                declick -= frames
            }
        }
        return produced
    }

    private func stretch(
        _ stretcher: Stretcher,
        _ left: UnsafeMutablePointer<Float>,
        _ right: UnsafeMutablePointer<Float>,
        count: Int
    ) -> Int {
        var produced = stretcher.retrieve(left, right, count: count)
        while produced < count, !stretcher.isFinished {
            let wanted = min(max(stretcher.required, 512), scratchCapacity)
            let got = readRing(scratchLeft, scratchRight, count: wanted)
            if got > 0 {
                stretcher.feed(scratchLeft, scratchRight, count: got)
            } else {
                lock.lock()
                let ended = (decoderAtEnd || failed) && pendingSeek == nil
                lock.unlock()
                guard ended else { break }
                stretcher.finish()
            }
            produced += stretcher.retrieve(left + produced, right + produced, count: count - produced)
        }
        return produced
    }
}
