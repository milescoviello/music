import CPulse
import Foundation
import Observation

/// The one stream to the sound server: PulseAudio's API, which PipeWire also serves, so
/// this reaches whatever the desktop runs.
///
/// Pull-driven. The server asks for audio when its buffer has room, on its own thread, and
/// `render` fills exactly what was asked for — which is how the mixer gets to decide every
/// sample, and so how gapless joins and fades can be exact rather than timed.
///
/// A twelfth of a second is buffered. Pausing corks the stream, keeping that buffer for
/// the resume; a skip or a seek flushes it, so the change is heard at once instead of
/// after it drains.
///
/// Locking order, everywhere: the mainloop lock, then the mixer's. The render callback
/// runs with the first held and takes the second, so the main thread must never call into
/// PulseAudio while holding the mixer's lock.
final class PulseOutput: @unchecked Sendable {
    static let shared = PulseOutput()

    /// Called on the server's thread with the mainloop lock held: fill `frames`
    /// interleaved stereo frames.
    var render: ((UnsafeMutablePointer<Float>, Int) -> Void)?

    private(set) var rate = 48_000
    private(set) var isConnected = false

    private let mainloop: OpaquePointer
    private var context: OpaquePointer?
    private var stream: OpaquePointer?
    private var corked = true
    private var sinkIndex: UInt32 = UInt32.max
    private var lastLatency: Double = 0

    static let bufferSeconds = 0.08

    private init() {
        mainloop = pa_threaded_mainloop_new()
        connect()
    }

    private var userdata: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    private static func from(_ data: UnsafeMutableRawPointer?) -> PulseOutput {
        Unmanaged<PulseOutput>.fromOpaque(data!).takeUnretainedValue()
    }

    // MARK: - Connecting

    private func connect() {
        let api = pa_threaded_mainloop_get_api(mainloop)
        let properties = pa_proplist_new()
        pa_proplist_sets(properties, "application.name", "Music")
        pa_proplist_sets(properties, "application.id", "com.milescoviello.Music")
        pa_proplist_sets(properties, "application.icon_name", "com.milescoviello.Music")
        context = pa_context_new_with_proplist(api, "Music", properties)
        pa_proplist_free(properties)
        guard let context else { return fail("no PulseAudio context") }

        pa_context_set_state_callback(context, { _, data in
            pa_threaded_mainloop_signal(PulseOutput.from(data).mainloop, 0)
        }, userdata)

        guard pa_context_connect(context, nil, PA_CONTEXT_NOFLAGS, nil) >= 0,
              pa_threaded_mainloop_start(mainloop) >= 0
        else { return fail("no sound server to connect to") }

        pa_threaded_mainloop_lock(mainloop)
        defer { pa_threaded_mainloop_unlock(mainloop) }

        while true {
            let state = pa_context_get_state(context)
            if state == PA_CONTEXT_READY { break }
            if !contextIsGood(state) { return fail("the sound server refused the connection") }
            pa_threaded_mainloop_wait(mainloop)
        }

        rate = serverRate() ?? 48_000
        openStream()
        subscribe()
    }

    /// The rate the server runs at — PipeWire's graph rate, usually 48 kHz — so the only
    /// resampling is the decoder's, done once per track at high quality.
    private func serverRate() -> Int? {
        guard let context else { return nil }
        final class Result { var rate: UInt32 = 0; var done = false }
        let result = Result()
        let box = Unmanaged.passRetained(Box((self, result)))
        let operation = pa_context_get_server_info(context, { _, info, data in
            let (output, result) = Unmanaged<Box<(PulseOutput, Result)>>.fromOpaque(data!).takeUnretainedValue().value
            result.rate = info?.pointee.sample_spec.rate ?? 0
            result.done = true
            pa_threaded_mainloop_signal(output.mainloop, 0)
        }, box.toOpaque())
        defer {
            if let operation { pa_operation_unref(operation) }
            box.release()
        }
        while !result.done, let operation, pa_operation_get_state(operation) == PA_OPERATION_RUNNING {
            pa_threaded_mainloop_wait(mainloop)
        }
        let rate = Int(result.rate)
        return (8_000...384_000).contains(rate) ? rate : nil
    }

    private func openStream() {
        guard let context else { return }
        var spec = pa_sample_spec(format: PA_SAMPLE_FLOAT32LE, rate: UInt32(rate), channels: 2)
        var map = pa_channel_map()
        pa_channel_map_init_stereo(&map)

        let properties = pa_proplist_new()
        pa_proplist_sets(properties, "media.role", "music")
        pa_proplist_sets(properties, "media.name", "Music")
        stream = pa_stream_new_with_proplist(context, "Music", &spec, &map, properties)
        pa_proplist_free(properties)
        guard let stream else { return fail("could not open a playback stream") }

        pa_stream_set_state_callback(stream, { _, data in
            pa_threaded_mainloop_signal(PulseOutput.from(data).mainloop, 0)
        }, userdata)
        pa_stream_set_write_callback(stream, { stream, bytes, data in
            PulseOutput.from(data).write(stream, bytes: bytes)
        }, userdata)
        pa_stream_set_moved_callback(stream, { stream, data in
            PulseOutput.from(data).moved(stream)
        }, userdata)

        let frameBytes = UInt32(MemoryLayout<Float>.size * 2)
        var attributes = pa_buffer_attr(
            maxlength: UInt32.max,
            tlength: UInt32(Double(rate) * Self.bufferSeconds) * frameBytes,
            prebuf: UInt32.max,
            minreq: UInt32(Double(rate) * 0.02) * frameBytes,
            fragsize: UInt32.max
        )
        let flags = pa_stream_flags_t(
            PA_STREAM_INTERPOLATE_TIMING.rawValue
                | PA_STREAM_AUTO_TIMING_UPDATE.rawValue
                | PA_STREAM_ADJUST_LATENCY.rawValue
                | PA_STREAM_START_CORKED.rawValue
        )
        guard pa_stream_connect_playback(stream, nil, &attributes, flags, nil, nil) >= 0 else {
            return fail("could not connect the playback stream")
        }
        while true {
            let state = pa_stream_get_state(stream)
            if state == PA_STREAM_READY { break }
            if !streamIsGood(state) { return fail("the playback stream failed") }
            pa_threaded_mainloop_wait(mainloop)
        }
        sinkIndex = pa_stream_get_device_index(stream)
        isConnected = true
    }

    private func fail(_ message: String) {
        Task { await Diagnostics.shared.record("audio", message) }
    }

    // MARK: - Rendering

    private func write(_ stream: OpaquePointer?, bytes: Int) {
        guard let stream else { return }
        var data: UnsafeMutableRawPointer?
        var size = bytes
        guard pa_stream_begin_write(stream, &data, &size) >= 0, let data, size > 0 else { return }
        let frames = size / (MemoryLayout<Float>.size * 2)
        let samples = data.assumingMemoryBound(to: Float.self)
        if let render {
            render(samples, frames)
        } else {
            samples.update(repeating: 0, count: frames * 2)
        }
        pa_stream_write(stream, data, frames * MemoryLayout<Float>.size * 2, nil, 0, PA_SEEK_RELATIVE)
    }

    // MARK: - Control (main thread)

    /// Runs `body` with the render callback held off, for changes that must land between
    /// two buffers — and, with `flush`, for those whose effect must be heard at once.
    func withRenderingHeld(flush: Bool = false, _ body: () -> Void) {
        pa_threaded_mainloop_lock(mainloop)
        body()
        if flush, let stream, let operation = pa_stream_flush(stream, nil, nil) {
            pa_operation_unref(operation)
        }
        pa_threaded_mainloop_unlock(mainloop)
    }

    func setPlaying(_ playing: Bool) {
        pa_threaded_mainloop_lock(mainloop)
        defer { pa_threaded_mainloop_unlock(mainloop) }
        guard let stream, corked == playing else { return }
        corked = !playing
        if let operation = pa_stream_cork(stream, playing ? 0 : 1, nil, nil) {
            pa_operation_unref(operation)
        }
    }

    /// Seconds between a sample being written now and being heard.
    func latency() -> Double {
        pa_threaded_mainloop_lock(mainloop)
        defer { pa_threaded_mainloop_unlock(mainloop) }
        guard let stream else { return 0 }
        var microseconds: pa_usec_t = 0
        var negative: Int32 = 0
        if pa_stream_get_latency(stream, &microseconds, &negative) == 0 {
            lastLatency = negative != 0 ? 0 : Double(microseconds) / 1_000_000
        }
        return lastLatency
    }

    // MARK: - Volume

    /// The stream's own volume, as the desktop's mixer shows it: 0...1, cubic, the way
    /// PulseAudio maps a slider.
    func setVolume(_ level: Double) {
        pa_threaded_mainloop_lock(mainloop)
        defer { pa_threaded_mainloop_unlock(mainloop) }
        guard let context, let stream else { return }
        var volume = pa_cvolume()
        pa_cvolume_set(&volume, 2, pa_sw_volume_from_linear(pow(min(max(level, 0), 1), 3)))
        if let operation = pa_context_set_sink_input_volume(context, pa_stream_get_index(stream), &volume, nil, nil) {
            pa_operation_unref(operation)
        }
    }

    /// Follows changes made elsewhere — the panel's mixer, `pavucontrol` — so the slider in
    /// the app never disagrees with the one in the desktop.
    private func subscribe() {
        guard let context else { return }
        pa_context_set_subscribe_callback(context, { _, event, index, data in
            let output = PulseOutput.from(data)
            let facility = event.rawValue & PA_SUBSCRIPTION_EVENT_FACILITY_MASK.rawValue
            guard facility == PA_SUBSCRIPTION_EVENT_SINK_INPUT.rawValue,
                  let stream = output.stream, index == pa_stream_get_index(stream)
            else { return }
            output.readVolume()
        }, userdata)
        if let operation = pa_context_subscribe(context, PA_SUBSCRIPTION_MASK_SINK_INPUT, nil, nil) {
            pa_operation_unref(operation)
        }
        readVolume()
    }

    /// Called with the mainloop lock held.
    private func readVolume() {
        guard let context, let stream else { return }
        let operation = pa_context_get_sink_input_info(context, pa_stream_get_index(stream), { _, info, eol, _ in
            guard eol == 0, let info else { return }
            var volume = info.pointee.volume
            let level = cbrt(pa_sw_volume_to_linear(pa_cvolume_avg(&volume)))
            Task { @MainActor in OutputVolume.shared.adopt(level) }
        }, nil)
        if let operation { pa_operation_unref(operation) }
    }

    // MARK: - Devices

    /// The server moved the stream. If the device it was on has gone — headphones out, a
    /// headset switched off — the music pauses rather than carrying on aloud.
    private func moved(_ stream: OpaquePointer?) {
        guard let context, let stream else { return }
        let previous = sinkIndex
        sinkIndex = pa_stream_get_device_index(stream)
        guard previous != UInt32.max else { return }
        let operation = pa_context_get_sink_info_by_index(context, previous, { _, _, eol, _ in
            // A negative end-of-list is the server saying there is no such sink.
            guard eol < 0 else { return }
            Task { @MainActor in AudioDevice.onLost?() }
        }, nil)
        if let operation { pa_operation_unref(operation) }
    }
}

/// The stream's volume, observable for the app's slider.
@MainActor
@Observable
final class OutputVolume {
    static let shared = OutputVolume()

    /// 0...1. Setting it moves the desktop's mixer too.
    var level: Double = 1 {
        didSet {
            guard !adopting, level != oldValue else { return }
            PulseOutput.shared.setVolume(level)
        }
    }

    @ObservationIgnored private var adopting = false

    fileprivate func adopt(_ level: Double) {
        guard abs(level - self.level) > 0.001 else { return }
        adopting = true
        self.level = level
        adopting = false
    }
}

private func contextIsGood(_ state: pa_context_state_t) -> Bool {
    state == PA_CONTEXT_CONNECTING || state == PA_CONTEXT_AUTHORIZING
        || state == PA_CONTEXT_SETTING_NAME || state == PA_CONTEXT_READY
}

private func streamIsGood(_ state: pa_stream_state_t) -> Bool {
    state == PA_STREAM_CREATING || state == PA_STREAM_READY
}
