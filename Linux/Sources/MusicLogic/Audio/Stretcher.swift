import CRubberBand

/// Speed without pitch: Rubber Band, in real-time mode, for one track.
///
/// What `AVPlayerItem.audioTimePitchAlgorithm = .spectral` was on the phone. It carries
/// both reasons a track plays at another speed — Plexamp's 0.5–2× speed control, and a
/// beat-matched fade's incoming track running at the outgoing one's tempo and easing back —
/// so its time ratio changes while it runs.
///
/// Created only when a track first needs a speed other than 1, and kept for the rest of
/// that track: switching back to the raw samples part way would be a seam. The start is
/// padded and the processing delay dropped, so the first sample out is the first sample
/// in — which is what lets a beat-matched start land where it was planned.
///
/// Render thread only.
final class Stretcher {
    private let state: RubberBandState
    private let rate: Int
    private var discard: Int
    private var finished = false
    private let silence: UnsafeMutablePointer<Float>
    private static let block = 1_024

    init?(rate: Int, tempo: Double) {
        let options = RubberBandOptionProcessRealTime.rawValue
            | RubberBandOptionEngineFiner.rawValue
            | RubberBandOptionChannelsTogether.rawValue
            | RubberBandOptionPitchHighConsistency.rawValue
        guard let state = rubberband_new(UInt32(rate), 2, Int32(bitPattern: options), 1 / tempo, 1) else {
            return nil
        }
        self.state = state
        self.rate = rate
        rubberband_set_max_process_size(state, UInt32(Self.block * 4))
        silence = .allocate(capacity: Self.block)
        silence.initialize(repeating: 0, count: Self.block)

        discard = Int(rubberband_get_start_delay(state))
        var pad = Int(rubberband_get_preferred_start_pad(state))
        while pad > 0 {
            let count = min(pad, Self.block)
            var inputs: [UnsafePointer<Float>?] = [UnsafePointer(silence), UnsafePointer(silence)]
            rubberband_process(state, &inputs, UInt32(count), 0)
            pad -= count
        }
    }

    deinit {
        rubberband_delete(state)
        silence.deallocate()
    }

    /// The speed relative to the source, where 2 is twice as fast.
    func setTempo(_ tempo: Double) {
        rubberband_set_time_ratio(state, 1 / max(tempo, 0.1))
    }

    /// Seconds of the source between what has been fed and what is being retrieved now.
    var latencySeconds: Double {
        Double(rubberband_get_latency(state)) / Double(rate)
    }

    /// Input frames the stretcher wants before it can produce more.
    var required: Int {
        max(Int(rubberband_get_samples_required(state)), 0)
    }

    /// Frames ready to retrieve, or -1 once the end has been fed and everything retrieved.
    var available: Int {
        Int(rubberband_available(state))
    }

    var isFinished: Bool { finished && available <= 0 }

    func feed(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, count: Int) {
        var inputs: [UnsafePointer<Float>?] = [left, right]
        var offset = 0
        while offset < count {
            let chunk = min(count - offset, Self.block * 4)
            inputs[0] = left + offset
            inputs[1] = right + offset
            rubberband_process(state, &inputs, UInt32(chunk), 0)
            offset += chunk
        }
    }

    /// The source has ended: whatever is still inside comes out.
    func finish() {
        guard !finished else { return }
        finished = true
        var inputs: [UnsafePointer<Float>?] = [UnsafePointer(silence), UnsafePointer(silence)]
        rubberband_process(state, &inputs, 0, 1)
    }

    /// Up to `count` frames into the two buffers. Returns how many.
    func retrieve(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, count: Int) -> Int {
        var produced = 0
        var outputs: [UnsafeMutablePointer<Float>?] = [left, right]
        while produced < count {
            let ready = available
            guard ready > 0 else { break }
            // The processing delay, dropped once at the start.
            if discard > 0 {
                let drop = min(discard, ready, Self.block)
                outputs[0] = silence
                outputs[1] = silence
                let got = Int(rubberband_retrieve(state, &outputs, UInt32(drop)))
                discard -= got
                silence.update(repeating: 0, count: Self.block)
                if got == 0 { break }
                continue
            }
            outputs[0] = left + produced
            outputs[1] = right + produced
            let got = Int(rubberband_retrieve(state, &outputs, UInt32(min(ready, count - produced))))
            guard got > 0 else { break }
            produced += got
        }
        return produced
    }
}
