import CFFmpeg
import Foundation
import Synchronization

/// One track, decoded by FFmpeg to planar 32-bit float stereo at the output's rate.
///
/// FFmpeg rather than GStreamer because it is one dependency with every decoder in it —
/// FLAC, ALAC, MP3, AAC, Opus, Vorbis, WavPack, Monkey's Audio — and its own HTTP(S), so
/// a stream and a file are opened the same way, and a distribution's GStreamer is often a
/// handful of separately packaged plugins with FLAC or MP3 missing.
///
/// Not thread-safe: each instance belongs to one decoding thread. `cancel()` is the
/// exception, and the reason it exists: a read blocked on a dead network returns at once.
final class AudioDecoder: @unchecked Sendable {
    enum Failure: Error {
        case open(String)
        case noAudio
        case codec
    }

    /// The decoded frames of one call, valid until the next.
    struct Chunk {
        let left: UnsafePointer<Float>
        let right: UnsafePointer<Float>
        let count: Int
    }

    let outputRate: Int32
    /// Seconds, from the container when it says; nil for a chunked stream that does not.
    private(set) var duration: Double?

    /// 1 for a mono file — whose one channel is copied into both outputs — else 2.
    var sourceChannels: Int { isMono ? 1 : 2 }

    private var format: UnsafeMutablePointer<AVFormatContext>?
    private var codec: UnsafeMutablePointer<AVCodecContext>?
    private var resampler: OpaquePointer?
    private var stream: UnsafeMutablePointer<AVStream>?
    private var streamIndex: Int32 = -1
    private let packet: UnsafeMutablePointer<AVPacket>
    private let frame: UnsafeMutablePointer<AVFrame>
    private var isMono = false
    private var draining = false

    /// Converted output, grown as needed and reused.
    private var left: UnsafeMutablePointer<Float>
    private var right: UnsafeMutablePointer<Float>
    private var capacity = 8_192

    /// After a seek, output before this time is decoded and thrown away: containers seek
    /// to a packet boundary, and a seek that lands a few hundred milliseconds early is a
    /// beat-matched fade that lands a few hundred milliseconds wrong.
    private var discardUntil: Double?

    private let cancelled = CancelFlag()
    private let url: URL

    final class CancelFlag: @unchecked Sendable {
        let value = Atomic<Bool>(false)
    }

    init(url: URL, outputRate: Int32) {
        self.url = url
        self.outputRate = outputRate
        packet = av_packet_alloc()
        frame = av_frame_alloc()
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
    }

    deinit {
        close()
        var packet: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&packet)
        var frame: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&frame)
        left.deallocate()
        right.deallocate()
    }

    /// Makes any blocking read return, and every later one fail. From any thread.
    func cancel() {
        cancelled.value.store(true, ordering: .relaxed)
    }

    // MARK: - Opening

    func open() throws {
        var context = avformat_alloc_context()
        context?.pointee.interrupt_callback = AVIOInterruptCB(
            callback: { opaque in
                guard let opaque else { return 0 }
                let flag = Unmanaged<CancelFlag>.fromOpaque(opaque).takeUnretainedValue()
                return flag.value.load(ordering: .relaxed) ? 1 : 0
            },
            opaque: Unmanaged.passUnretained(cancelled).toOpaque()
        )

        var options: OpaquePointer?
        if !url.isFileURL {
            // A stream that drops reconnects where it was rather than ending the track,
            // and one that hangs gives up after fifteen seconds instead of forever.
            for (key, value) in [
                ("reconnect", "1"),
                ("reconnect_streamed", "1"),
                ("reconnect_on_network_error", "1"),
                ("reconnect_delay_max", "4"),
                ("rw_timeout", "15000000"),
                ("user_agent", "Music (Linux)"),
            ] {
                av_dict_set(&options, key, value, 0)
            }
        }
        let location = url.isFileURL ? url.path : url.absoluteString
        let opened = avformat_open_input(&context, location, nil, &options)
        av_dict_free(&options)
        guard opened >= 0, let context else {
            throw Failure.open(Self.describe(opened))
        }
        format = context

        guard avformat_find_stream_info(context, nil) >= 0 else { throw Failure.noAudio }

        var decoder: UnsafePointer<AVCodec>?
        streamIndex = av_find_best_stream(context, AVMEDIA_TYPE_AUDIO, -1, -1, &decoder, 0)
        guard streamIndex >= 0, let decoder, let stream = context.pointee.streams[Int(streamIndex)] else {
            throw Failure.noAudio
        }
        self.stream = stream

        guard let codec = avcodec_alloc_context3(decoder) else { throw Failure.codec }
        self.codec = codec
        avcodec_parameters_to_context(codec, stream.pointee.codecpar)
        codec.pointee.pkt_timebase = stream.pointee.time_base
        guard avcodec_open2(codec, decoder, nil) >= 0 else { throw Failure.codec }

        if context.pointee.duration > 0 {
            duration = Double(context.pointee.duration) / Double(AV_TIME_BASE)
        } else if stream.pointee.duration > 0 {
            duration = Double(stream.pointee.duration) * av_q2d(stream.pointee.time_base)
        }

        try makeResampler()
    }

    /// To stereo at the output rate. A mono file is resampled as mono and copied into both
    /// channels: swresample's own upmix puts the centre in each side at −3 dB, which would
    /// make every mono recording audibly quieter than its neighbours.
    private func makeResampler() throws {
        guard let codec else { throw Failure.codec }
        if codec.pointee.ch_layout.order == AV_CHANNEL_ORDER_UNSPEC {
            let channels = codec.pointee.ch_layout.nb_channels
            av_channel_layout_uninit(&codec.pointee.ch_layout)
            av_channel_layout_default(&codec.pointee.ch_layout, channels)
        }
        isMono = codec.pointee.ch_layout.nb_channels == 1

        var layout = AVChannelLayout()
        av_channel_layout_default(&layout, isMono ? 1 : 2)
        defer { av_channel_layout_uninit(&layout) }

        swr_free(&resampler)
        let made = swr_alloc_set_opts2(
            &resampler,
            &layout, AV_SAMPLE_FMT_FLTP, outputRate,
            &codec.pointee.ch_layout, codec.pointee.sample_fmt, codec.pointee.sample_rate,
            0, nil
        )
        guard made >= 0, resampler != nil, swr_init(resampler) >= 0 else { throw Failure.codec }
    }

    func close() {
        swr_free(&resampler)
        if codec != nil { avcodec_free_context(&codec) }
        if format != nil { avformat_close_input(&format) }
        stream = nil
    }

    // MARK: - Decoding

    /// The next decoded frames, or nil at the end of the track. Throws on a read or decode
    /// error that FFmpeg could not recover from.
    func next() throws -> Chunk? {
        guard let format, let codec else { return nil }
        while true {
            let received = avcodec_receive_frame(codec, frame)
            if received == 0 {
                defer { av_frame_unref(frame) }
                if let chunk = convert() { return chunk }
                continue
            }
            if received == cffmpeg_error_eof() {
                return flushResampler()
            }
            guard received == cffmpeg_error_again() else {
                throw Failure.open(Self.describe(received))
            }
            guard !draining else { return flushResampler() }

            let read = av_read_frame(format, packet)
            if read < 0 {
                if read == cffmpeg_error_eof() || format.pointee.pb?.pointee.eof_reached != 0 {
                    // Ask the decoder for whatever it is still holding.
                    draining = true
                    avcodec_send_packet(codec, nil)
                    continue
                }
                throw Failure.open(Self.describe(read))
            }
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == streamIndex else { continue }
            let sent = avcodec_send_packet(codec, packet)
            // A damaged packet is skipped rather than ending the track.
            if sent < 0, sent != cffmpeg_error_again() { continue }
        }
    }

    private func ensureCapacity(_ frames: Int) {
        guard frames > capacity else { return }
        capacity = frames
        left.deallocate()
        right.deallocate()
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
    }

    private func convert() -> Chunk? {
        guard let resampler else { return nil }
        let wanted = Int(swr_get_out_samples(resampler, frame.pointee.nb_samples))
        ensureCapacity(max(wanted, 1))

        var outputs: [UnsafeMutablePointer<UInt8>?] = [
            UnsafeMutableRawPointer(left).assumingMemoryBound(to: UInt8.self),
            UnsafeMutableRawPointer(right).assumingMemoryBound(to: UInt8.self),
        ]
        let input = UnsafeRawPointer(frame.pointee.extended_data).assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
        let count = Int(swr_convert(resampler, &outputs, Int32(capacity), input, frame.pointee.nb_samples))
        guard count > 0 else { return nil }
        if isMono { right.update(from: left, count: count) }

        // Thrown away up to the seek target, measured from this frame's own timestamp.
        var skip = 0
        if let target = discardUntil, let stream {
            let stamp = frame.pointee.best_effort_timestamp
            if stamp != cffmpeg_nopts() {
                let start = Double(stamp) * av_q2d(stream.pointee.time_base)
                skip = max(0, min(count, Int(((target - start) * Double(outputRate)).rounded())))
                if skip < count { discardUntil = nil }
            } else {
                discardUntil = nil
            }
        }
        guard skip < count else { return nil }
        return Chunk(left: left + skip, right: right + skip, count: count - skip)
    }

    /// The last few samples the resampler holds once the decoder has nothing left.
    private func flushResampler() -> Chunk? {
        guard let resampler else { return nil }
        ensureCapacity(4_096)
        var outputs: [UnsafeMutablePointer<UInt8>?] = [
            UnsafeMutableRawPointer(left).assumingMemoryBound(to: UInt8.self),
            UnsafeMutableRawPointer(right).assumingMemoryBound(to: UInt8.self),
        ]
        let count = Int(swr_convert(resampler, &outputs, Int32(capacity), nil, 0))
        guard count > 0 else { return nil }
        if isMono { right.update(from: left, count: count) }
        return Chunk(left: left, right: right, count: count)
    }

    // MARK: - Seeking

    /// Seeks to a time, exactly: the next chunk starts there. False when the source cannot
    /// seek — a transcode sent chunked, with no length — in which case the caller reopens
    /// and decodes forward.
    func seek(to seconds: Double) -> Bool {
        guard let format, let codec, let stream else { return false }
        let target = max(0, seconds)
        let timestamp = Int64(target / av_q2d(stream.pointee.time_base))
        guard av_seek_frame(format, streamIndex, timestamp, AVSEEK_FLAG_BACKWARD) >= 0 else { return false }
        avcodec_flush_buffers(codec)
        draining = false
        swr_init(resampler)
        discardUntil = target > 0 ? target : nil
        return true
    }

    /// For a source that cannot seek: everything before `seconds` is decoded and dropped,
    /// from wherever the decoder is now.
    func skipForward(to seconds: Double) {
        discardUntil = seconds
    }

    private static func describe(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        av_strerror(code, &buffer, buffer.count)
        return String(cString: buffer)
    }
}
