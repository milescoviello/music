import CFFmpeg
import CGtk
import CPulse
import Foundation
import Synchronization

/// Plays a music video on the desktop: the tallest H.264 stream and the best (Opus) audio
/// the sonic service relays (`VideoClient.streams`), decoded by FFmpeg -- the same
/// library the player's own sound comes from -- with no ads, since none of YouTube's
/// player is involved.
///
/// The sound is its own PulseAudio stream beside the player's, which is paused meanwhile,
/// and the sound is the clock: each picture is shown when the audio that goes with it is
/// being heard (`present`, from the surfaces' frame callbacks). Without a sound server --
/// the headless sandbox -- the wall clock stands in, so the picture still plays.
///
/// Same shape as the phone's `App/Core/VideoEngine.swift`, so `VideoService` drives both.
@MainActor
final class VideoEngine {
    struct Progress: Equatable, Sendable {
        var elapsed: Double
        var duration: Double
        var isPlaying: Bool
        var isWaiting: Bool
    }

    var onProgress: ((Progress) -> Void)?
    var onEnd: (() -> Void)?
    var onFailure: ((String) -> Void)?
    /// A new picture to show; the surfaces listen.
    var onFrame: ((Texture?) -> Void)?

    private(set) var currentFrame: Texture?
    private var session: VideoSession?
    private var streams: (id: String, quality: VideoQuality, streams: VideoClient.Streams, video: URL, audio: URL)?
    private var client: VideoClient?
    private var videoID: String?
    private var wantsPlaying = false
    private var duration: Double = 0
    private var surfaces = 0
    private var generation = 0
    private var ticker: Task<Void, Never>?
    private var isOpening = false
    private var finished = false

    var isOpen: Bool { videoID != nil }
    /// The Streaming settings' video quality: the tallest, or the height chosen.
    var quality: VideoQuality = .auto

    func open(videoID: String, client: VideoClient, at seconds: Double, playing: Bool) {
        stop()
        self.videoID = videoID
        self.client = client
        wantsPlaying = playing
        start(at: seconds)
    }

    func play() {
        wantsPlaying = true
        if finished, let videoID, let client {
            // Played again after it ended: from the top.
            open(videoID: videoID, client: client, at: 0, playing: true)
            return
        }
        session?.setPlaying(true)
        report()
    }

    func pause() {
        wantsPlaying = false
        session?.setPlaying(false)
        report()
    }

    /// Reopens both streams at the new time: they come from the service on the same
    /// network, so this is quick, and it keeps the two decoders exactly together.
    func seek(to seconds: Double) {
        guard videoID != nil else { return }
        start(at: max(0, min(seconds, duration > 0 ? duration - 0.5 : seconds)))
    }

    func stop() {
        generation += 1
        session?.stop()
        session = nil
        ticker?.cancel()
        ticker = nil
        videoID = nil
        client = nil
        isOpening = false
        finished = false
        wantsPlaying = false
        if currentFrame != nil {
            currentFrame = nil
            onFrame?(nil)
        }
    }

    // MARK: - Surfaces

    /// A surface is showing the video. While none is, frames are decoded and dropped
    /// without being scaled, and only the sound plays.
    func attachSurface() {
        surfaces += 1
        session?.setWantsPictures(true)
    }

    func detachSurface() {
        surfaces = max(0, surfaces - 1)
        session?.setWantsPictures(surfaces > 0)
    }

    /// From a surface's frame callback: the picture due now, if it changed.
    @discardableResult
    func present() -> Texture? {
        guard let session, let frame = session.takeDue() else { return currentFrame }
        let texture = frame.pixels.withUnsafeBytes { buffer -> Texture in
            let bytes = g_bytes_new(buffer.baseAddress, gsize(buffer.count))
            defer { g_bytes_unref(bytes) }
            return Texture(adopting: gdk_memory_texture_new(
                Int32(frame.width), Int32(frame.height), GDK_MEMORY_R8G8B8, bytes, gsize(frame.stride)
            )!)
        }
        currentFrame = texture
        onFrame?(texture)
        return texture
    }

    // MARK: - Opening

    private func start(at seconds: Double) {
        generation += 1
        let generation = generation
        session?.stop()
        session = nil
        finished = false
        isOpening = true
        report(elapsed: seconds)
        startTicker()
        guard let videoID, let client else { return }

        Task {
            let resolved: (id: String, quality: VideoQuality, streams: VideoClient.Streams, video: URL, audio: URL)
            let quality = quality
            if let kept = streams, kept.id == videoID, kept.quality == quality {
                resolved = kept
            } else {
                do {
                    let answer = try await client.streams(videoID: videoID, quality: quality)
                    guard let video = client.mediaURL(answer.video), let audio = client.mediaURL(answer.audio) else {
                        throw SonicError.badURL
                    }
                    resolved = (videoID, quality, answer, video, audio)
                } catch {
                    guard self.generation == generation else { return }
                    fail("The video service couldn't open this video.")
                    return
                }
            }
            guard self.generation == generation else { return }
            streams = resolved
            duration = resolved.streams.duration
            let session = VideoSession(
                video: resolved.video, audio: resolved.audio, start: seconds,
                playing: wantsPlaying, pictures: surfaces > 0, volume: Float(OutputVolume.shared.level)
            )
            self.session = session
            session.start()
        }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.tick()
            }
        }
    }

    private func tick() {
        guard let session else {
            if isOpening { report() }
            return
        }
        if let failure = session.failure {
            fail(failure)
            return
        }
        session.setVolume(Float(OutputVolume.shared.level))
        if surfaces == 0 { session.dropDue() }
        if session.isOpen { isOpening = false }
        report()
        if session.hasEnded, !finished {
            finished = true
            wantsPlaying = false
            session.setPlaying(false)
            report()
            onEnd?()
        }
    }

    private func report(elapsed: Double? = nil) {
        guard videoID != nil else { return }
        let now = elapsed ?? session?.clock() ?? 0
        onProgress?(Progress(
            elapsed: max(0, min(now, duration > 0 ? duration : now)),
            duration: duration,
            isPlaying: wantsPlaying,
            isWaiting: isOpening || (wantsPlaying && session?.isWaiting == true)
        ))
    }

    private func fail(_ message: String) {
        stop()
        onFailure?(message)
    }
}

// MARK: - The decoding threads

/// One opened video: a thread decoding the sound into its own PulseAudio stream, which
/// keeps the time, and one decoding the pictures a few frames ahead of it.
final class VideoSession: @unchecked Sendable {
    struct Frame {
        let time: Double
        let pixels: [UInt8]
        let width: Int
        let height: Int
        let stride: Int
    }

    private let videoURL: URL
    private let audioURL: URL
    private let startTime: Double
    private let rate = 48_000

    private let condition = NSCondition()
    // Guarded by `condition`.
    private var playing: Bool
    private var stopped = false
    private var wantsPictures: Bool
    private var volume: Float
    private var frames: [Frame] = []
    /// The first picture after opening is shown at once, even paused: after a seek, the
    /// frame there is a hair past the time asked for, and a paused clock never reaches it.
    private var shownFirst = false
    /// Pictures wanted again after none were: the decoder had skipped them, so it goes back
    /// to the time heard now, or a paused video showed black until it was played.
    private var resync = false
    private var audioOpen = false
    private var videoOpen = false
    private var audioEnded = false
    private var videoEnded = false
    private var failureMessage: String?
    /// The time being heard at `clockStamp`, and whether it moves on from there.
    private var clockAt: Double
    private var clockStamp = Date.now
    private var clockMoving = false
    private var lastWrite = Date.now

    private var audioDecoder: AudioDecoder?
    private var videoDecoder: VideoDecoder?
    private static let queueLength = 8

    init(video: URL, audio: URL, start: Double, playing: Bool, pictures: Bool, volume: Float) {
        videoURL = video
        audioURL = audio
        startTime = start
        self.playing = playing
        wantsPictures = pictures
        self.volume = volume
        clockAt = start
    }

    func start() {
        let audio = Thread { [self] in runAudio() }
        audio.name = "video sound"
        audio.qualityOfService = .userInteractive
        audio.start()
        let video = Thread { [self] in runVideo() }
        video.name = "video pictures"
        video.qualityOfService = .userInitiated
        video.start()
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
        audioDecoder?.cancel()
        videoDecoder?.cancel()
    }

    // MARK: Asked from the main actor

    var failure: String? { locked { failureMessage } }
    var isOpen: Bool { locked { audioOpen && videoOpen } }
    var hasEnded: Bool { locked { audioEnded && (videoEnded || !wantsPictures) && frames.isEmpty } }
    /// Open, asked to play, and no sound written for a while: the network is behind.
    var isWaiting: Bool { locked { !(audioOpen && videoOpen) || (playing && !audioEnded && Date.now.timeIntervalSince(lastWrite) > 0.6) } }

    func setPlaying(_ value: Bool) {
        condition.lock()
        if value != playing {
            clockAt = currentClock()
            clockStamp = .now
            playing = value
            clockMoving = false
        }
        condition.broadcast()
        condition.unlock()
    }

    func setWantsPictures(_ value: Bool) {
        condition.lock()
        if value, !wantsPictures {
            resync = true
            shownFirst = false
            frames.removeAll()
        }
        wantsPictures = value
        condition.broadcast()
        condition.unlock()
    }

    func setVolume(_ value: Float) {
        locked { volume = value }
    }

    /// The time being heard now.
    func clock() -> Double {
        locked { currentClock() }
    }

    /// The newest frame whose time has come, dropping any older ones. Nil when none is due.
    func takeDue() -> Frame? {
        condition.lock()
        defer { condition.unlock() }
        let now = currentClock()
        var due: Frame?
        if !shownFirst, !frames.isEmpty {
            shownFirst = true
            due = frames.removeFirst()
        }
        while let first = frames.first, first.time <= now + 0.012 {
            due = frames.removeFirst()
        }
        if due != nil { condition.broadcast() }
        return due
    }

    func dropDue() {
        _ = takeDue()
    }

    // Called with the lock held.
    private func currentClock() -> Double {
        guard clockMoving, playing else { return clockAt }
        return clockAt + Date.now.timeIntervalSince(clockStamp)
    }

    private func locked<T>(_ body: () -> T) -> T {
        condition.lock()
        defer { condition.unlock() }
        return body()
    }

    private func failed(_ message: String) {
        locked { if failureMessage == nil { failureMessage = message } }
    }

    // MARK: The sound, and the clock

    private func runAudio() {
        let decoder = AudioDecoder(url: audioURL, outputRate: Int32(rate))
        audioDecoder = decoder
        do {
            try decoder.open()
        } catch {
            if !locked({ stopped }) { failed("The video's sound wouldn't open.") }
            return
        }
        if startTime > 0 { _ = decoder.seek(to: startTime) }

        var spec = pa_sample_spec(format: PA_SAMPLE_FLOAT32LE, rate: UInt32(rate), channels: 2)
        // A fifth of a second queued: enough not to underrun, little enough that pause
        // and seek are heard at once.
        var attributes = pa_buffer_attr(
            maxlength: UInt32.max, tlength: UInt32(rate / 5 * 8), prebuf: UInt32.max,
            minreq: UInt32.max, fragsize: UInt32.max
        )
        var error: Int32 = 0
        let pulse = pa_simple_new(nil, "Music", PA_STREAM_PLAYBACK, nil, "Music video", &spec, nil, &attributes, &error)
        defer {
            if let pulse {
                pa_simple_flush(pulse, &error)
                pa_simple_free(pulse)
            }
        }
        locked {
            audioOpen = true
            lastWrite = .now
        }

        var written = 0.0
        var interleaved = [Float]()
        while true {
            condition.lock()
            var wasPaused = false
            while !playing, !stopped {
                if !wasPaused, let pulse {
                    // Heard stopping at once, not a fifth of a second later.
                    pa_simple_flush(pulse, &error)
                }
                wasPaused = true
                condition.wait()
            }
            let isStopped = stopped
            let gain = volume
            condition.unlock()
            if isStopped { return }
            if wasPaused {
                // What was queued and flushed was never heard: the time goes back to the
                // clock's, where it stopped.
                written = locked { clockAt } - startTime
            }

            let chunk: AudioDecoder.Chunk?
            do {
                chunk = try decoder.next()
            } catch {
                if !locked({ stopped }) { failed("The video's sound stopped.") }
                return
            }
            guard let chunk else {
                if let pulse { pa_simple_drain(pulse, &error) }
                // The wall clock carries the time on from here, so pictures still queued
                // come due and the end is reached.
                locked {
                    clockAt = startTime + written
                    clockStamp = .now
                    clockMoving = true
                    audioEnded = true
                }
                return
            }

            let count = chunk.count
            if interleaved.count < count * 2 { interleaved = [Float](repeating: 0, count: count * 2) }
            for index in 0..<count {
                interleaved[index * 2] = chunk.left[index] * gain
                interleaved[index * 2 + 1] = chunk.right[index] * gain
            }
            if let pulse {
                let result = interleaved.withUnsafeBytes { buffer in
                    pa_simple_write(pulse, buffer.baseAddress, count * 2 * MemoryLayout<Float>.size, &error)
                }
                if result < 0 {
                    failed("The sound server stopped taking the video's sound.")
                    return
                }
            } else {
                // No sound server: the wall clock paces it instead.
                Thread.sleep(forTimeInterval: Double(count) / Double(rate))
            }
            written += Double(count) / Double(rate)
            let latency = pulse.map { Double(pa_simple_get_latency($0, &error)) / 1_000_000 } ?? 0
            locked {
                clockAt = startTime + max(0, written - latency)
                clockStamp = .now
                clockMoving = true
                lastWrite = .now
            }
        }
    }

    // MARK: The pictures

    private func runVideo() {
        let decoder = VideoDecoder(url: videoURL)
        videoDecoder = decoder
        do {
            try decoder.open()
        } catch {
            if !locked({ stopped }) { failed("The video's picture wouldn't open.") }
            return
        }
        if startTime > 0 { decoder.seek(to: startTime) }
        locked { videoOpen = true }
        var from = startTime

        while true {
            if locked({ stopped }) { return }
            if let now = locked({ () -> Double? in
                guard resync else { return nil }
                resync = false
                return currentClock()
            }) {
                decoder.seek(to: now)
                from = now
            }
            let time: Double
            do {
                guard let next = try decoder.nextFrame() else {
                    locked { videoEnded = true }
                    return
                }
                time = next
            } catch {
                if !locked({ stopped }) { failed("The video's picture stopped.") }
                return
            }
            // Before the place asked for: the decoder starts from the key frame before it.
            if time < from - 0.02 { continue }

            condition.lock()
            // Never far ahead of the sound, and never more than a few frames queued.
            while !stopped, !resync, frames.count >= Self.queueLength || time > currentClock() + 1.5 {
                _ = condition.wait(until: Date.now.addingTimeInterval(0.02))
            }
            if resync {
                condition.unlock()
                continue
            }
            let showing = wantsPictures
            let late = time < currentClock() - 0.1 && !frames.isEmpty
            let isStopped = stopped
            condition.unlock()
            if isStopped { return }
            guard showing, !late else { continue }

            guard let frame = decoder.scaled(time: time, maxWidth: 1920, maxHeight: 1080) else { continue }
            condition.lock()
            frames.append(frame)
            condition.unlock()
        }
    }
}

/// The video stream's decoder: FFmpeg's, frames scaled to packed RGB.
final class VideoDecoder: @unchecked Sendable {
    enum Failure: Error {
        case open(String)
        case noVideo
        case codec
    }

    private let url: URL
    private var format: UnsafeMutablePointer<AVFormatContext>?
    private var codec: UnsafeMutablePointer<AVCodecContext>?
    private var stream: UnsafeMutablePointer<AVStream>?
    private var streamIndex: Int32 = -1
    private let packet: UnsafeMutablePointer<AVPacket>
    private let frame: UnsafeMutablePointer<AVFrame>
    private var scaler: UnsafeMutableRawPointer?
    private var draining = false
    private let cancelled = AudioDecoder.CancelFlag()

    init(url: URL) {
        self.url = url
        packet = av_packet_alloc()
        frame = av_frame_alloc()
    }

    deinit {
        cffmpeg_scale_free(&scaler)
        if codec != nil { avcodec_free_context(&codec) }
        if format != nil { avformat_close_input(&format) }
        var packet: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&packet)
        var frame: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&frame)
    }

    func cancel() {
        cancelled.value.store(true, ordering: .relaxed)
    }

    func open() throws {
        var context = avformat_alloc_context()
        context?.pointee.interrupt_callback = AVIOInterruptCB(
            callback: { opaque in
                guard let opaque else { return 0 }
                let flag = Unmanaged<AudioDecoder.CancelFlag>.fromOpaque(opaque).takeUnretainedValue()
                return flag.value.load(ordering: .relaxed) ? 1 : 0
            },
            opaque: Unmanaged.passUnretained(cancelled).toOpaque()
        )
        var options: OpaquePointer?
        for (key, value) in [
            ("reconnect", "1"),
            ("reconnect_on_network_error", "1"),
            ("reconnect_delay_max", "4"),
            ("rw_timeout", "15000000"),
            ("user_agent", "Music (Linux)"),
        ] {
            av_dict_set(&options, key, value, 0)
        }
        let opened = avformat_open_input(&context, url.absoluteString, nil, &options)
        av_dict_free(&options)
        guard opened >= 0, let context else { throw Failure.open("could not open: \(opened)") }
        format = context
        guard avformat_find_stream_info(context, nil) >= 0 else { throw Failure.noVideo }

        var decoder: UnsafePointer<AVCodec>?
        streamIndex = av_find_best_stream(context, AVMEDIA_TYPE_VIDEO, -1, -1, &decoder, 0)
        guard streamIndex >= 0, let decoder, let stream = context.pointee.streams[Int(streamIndex)] else {
            throw Failure.noVideo
        }
        self.stream = stream
        guard let codec = avcodec_alloc_context3(decoder) else { throw Failure.codec }
        self.codec = codec
        guard avcodec_parameters_to_context(codec, stream.pointee.codecpar) >= 0 else { throw Failure.codec }
        // Every core: 1080p H.264 in software, at a fraction of real time.
        codec.pointee.thread_count = 0
        codec.pointee.thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE
        guard avcodec_open2(codec, decoder, nil) >= 0 else { throw Failure.codec }
    }

    func seek(to seconds: Double) {
        guard let format, let codec, let stream else { return }
        let timestamp = Int64(max(0, seconds) / av_q2d(stream.pointee.time_base))
        if av_seek_frame(format, streamIndex, timestamp, AVSEEK_FLAG_BACKWARD) >= 0 {
            avcodec_flush_buffers(codec)
            draining = false
        }
    }

    /// Decodes the next frame and returns its time in seconds; nil at the end.
    func nextFrame() throws -> Double? {
        guard let format, let codec, let stream else { return nil }
        while true {
            let received = avcodec_receive_frame(codec, frame)
            if received >= 0 {
                let stamp = frame.pointee.best_effort_timestamp != cffmpeg_nopts()
                    ? frame.pointee.best_effort_timestamp : frame.pointee.pts
                return Double(stamp) * av_q2d(stream.pointee.time_base)
            }
            if received == cffmpeg_error_eof() { return nil }
            guard received == cffmpeg_error_again() else { throw Failure.codec }
            if draining { return nil }

            let read = av_read_frame(format, packet)
            if read < 0 {
                if cancelled.value.load(ordering: .relaxed) { return nil }
                guard read == cffmpeg_error_eof() else { throw Failure.open("read failed: \(read)") }
                draining = true
                avcodec_send_packet(codec, nil)
                continue
            }
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == streamIndex else { continue }
            _ = avcodec_send_packet(codec, packet)
        }
    }

    /// The last decoded frame as packed RGB, no larger than asked and never enlarged.
    func scaled(time: Double, maxWidth: Int, maxHeight: Int) -> VideoSession.Frame? {
        let sourceWidth = Int(frame.pointee.width)
        let sourceHeight = Int(frame.pointee.height)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let factor = min(1, min(Double(maxWidth) / Double(sourceWidth), Double(maxHeight) / Double(sourceHeight)))
        // Even sizes: the scaler's chroma handling wants them.
        let width = max(2, Int(Double(sourceWidth) * factor) & ~1)
        let height = max(2, Int(Double(sourceHeight) * factor) & ~1)
        // Rows 64-byte aligned, with room to spare after the last: swscale's SIMD writes
        // run past the end of a row, which in an exact-size buffer is past the end of the
        // buffer -- FFmpeg's own frames are padded for exactly this.
        let stride = (width * 3 + 63) & ~63
        var pixels = [UInt8](repeating: 0, count: stride * (height + 1) + 128)
        let result = pixels.withUnsafeMutableBufferPointer { buffer in
            cffmpeg_scale_rgb(&scaler, frame, Int32(width), Int32(height), buffer.baseAddress, Int32(stride))
        }
        guard result > 0 else { return nil }
        return VideoSession.Frame(time: time, pixels: pixels, width: width, height: height, stride: stride)
    }
}
