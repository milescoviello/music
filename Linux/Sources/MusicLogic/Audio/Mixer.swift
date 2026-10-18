import Foundation

/// The sample-level half of the player: what plays, how loud, and when the next track
/// comes in — decided per sample, on the sound server's thread, as each buffer is filled.
///
/// On the phone, `QueuePlayerOutput` drives two `AVQueuePlayer`s from the main actor and
/// has to schedule a beat-matched start against the host clock to land it on time. Here the
/// mixer writes every sample itself, so the same plans are simpler and exact:
///
/// - A **gapless** join is the next track's first sample written right after the last
///   track's last, in the same buffer.
/// - A **fade** starts at the sample where the outgoing track reaches its fade point, with
///   equal-power gains computed per sample.
/// - A **beat-matched** start is the incoming track's first sample written at the sample
///   where the outgoing one reaches the planned beat, at the planned tempo, easing back to
///   its own once the fade is over.
///
/// What plays and what is planned is set by `QueuePlayerOutput` on the main actor, which
/// applies Sweet Fades' rules; the mixer executes. What it did is recorded in a timeline
/// of output frames, which the main actor reads against the stream's latency to know what
/// is being *heard* — the track the lock screen should show, and where in it.
final class Mixer: @unchecked Sendable {
    let rate: Int
    let lock = NSLock()

    // MARK: State, guarded by `lock`

    /// What is playing: the current track and its gapless continuation.
    var active: Voice?
    /// Ready for the planned fade: the track it brings in, and its continuation.
    var incoming: Voice?
    /// Fading out under the active voice.
    var fading: [Voice] = []
    /// The fade from the active voice's current track into `incoming`'s, if one is planned.
    var plan: FadePlan?
    /// Playback speed, pitch preserved; multiplies every voice's own tempo.
    var speed: Double = 1
    /// The sleep timer's fade. Multiplies with any crossfade, never replaces it.
    var volume: Float = 1
    /// Where to copy what the active voice plays, for the visualiser.
    var spectrum: AudioSampleBuffer?
    /// Frames written to the stream since it opened.
    private(set) var writtenFrames: Int64 = 0
    /// Sources finished with on the render thread, released on the main actor: a source's
    /// decoder thread is told to stop, which is no work for this thread.
    var released: [TrackSource] = []
    /// Things worth a line in Diagnostics, collected here and recorded by the main actor.
    var notes: [String] = []
    /// Whether the active voice's track was moving at the end of the last buffer.
    private(set) var isStalled = false

    let timeline = Timeline()

    // MARK: Render-thread buffers

    private var voiceLeft: UnsafeMutablePointer<Float>
    private var voiceRight: UnsafeMutablePointer<Float>
    private var mixLeft: UnsafeMutablePointer<Float>
    private var mixRight: UnsafeMutablePointer<Float>
    private var capacity = 0
    private var appliedVolume: Float = 1

    init(rate: Int) {
        self.rate = rate
        voiceLeft = .allocate(capacity: 1)
        voiceRight = .allocate(capacity: 1)
        mixLeft = .allocate(capacity: 1)
        mixRight = .allocate(capacity: 1)
        released.reserveCapacity(32)
        notes.reserveCapacity(16)
        ensureCapacity(16_384)
    }

    deinit {
        voiceLeft.deallocate()
        voiceRight.deallocate()
        mixLeft.deallocate()
        mixRight.deallocate()
    }

    private func ensureCapacity(_ frames: Int) {
        guard frames > capacity else { return }
        capacity = frames
        for pointer in [voiceLeft, voiceRight, mixLeft, mixRight] { pointer.deallocate() }
        voiceLeft = .allocate(capacity: frames)
        voiceRight = .allocate(capacity: frames)
        mixLeft = .allocate(capacity: frames)
        mixRight = .allocate(capacity: frames)
    }

    // MARK: - Rendering

    /// Fills `frames` interleaved stereo frames. Called by `PulseOutput` on its thread.
    func render(into output: UnsafeMutablePointer<Float>, frames: Int) {
        lock.lock()
        defer { lock.unlock() }
        ensureCapacity(frames)
        mixLeft.update(repeating: 0, count: frames)
        mixRight.update(repeating: 0, count: frames)

        var cursor = 0
        while cursor < frames {
            if beginFadeIfDue() { continue }
            let segment = min(frames - cursor, framesUntilFade() ?? frames)
            renderSegment(at: cursor, count: max(1, segment))
            cursor += max(1, segment)
        }

        // The sleep timer's fade, ramped across the buffer so a step is never a click.
        let start = appliedVolume
        let end = volume
        let step = (end - start) / Float(frames)
        for frame in 0..<frames {
            let gain = start + step * Float(frame + 1)
            output[frame * 2] = mixLeft[frame] * gain
            output[frame * 2 + 1] = mixRight[frame] * gain
        }
        appliedVolume = end
        writtenFrames += Int64(frames)
    }

    /// The active voice and anything fading out, for `count` frames from `offset`.
    private func renderSegment(at offset: Int, count: Int) {
        if let active {
            renderVoice(active, at: offset, count: count, isCurrent: true)
            if active.sources.isEmpty {
                // Ran out before its fade point, or with nothing planned at all.
                if let incoming {
                    self.active = incoming
                    self.incoming = nil
                    plan = nil
                } else {
                    self.active = nil
                    timeline.append(frame: writtenFrames + Int64(offset + count), songID: nil, position: 0, step: 0)
                }
            }
        } else {
            timeline.append(frame: writtenFrames + Int64(offset), songID: nil, position: 0, step: 0)
        }

        for voice in fading {
            renderVoice(voice, at: offset, count: count, isCurrent: false)
        }
        fading.removeAll { voice in
            guard voice.isSilentForGood else { return false }
            released.append(contentsOf: voice.sources)
            voice.sources.removeAll()
            return true
        }
    }

    private func renderVoice(_ voice: Voice, at offset: Int, count: Int, isCurrent: Bool) {
        let tempo = voice.advanceTempo(by: count, rate: rate)
        var produced = 0
        var stalled = false
        while produced < count, let source = voice.sources.first {
            if isCurrent {
                timeline.append(
                    frame: writtenFrames + Int64(offset + produced),
                    songID: source.song.id,
                    position: source.position,
                    step: tempo * speed / Double(rate)
                )
            }
            let got = source.pull(voiceLeft + produced, voiceRight + produced, count: count - produced, tempo: tempo * speed)
            produced += got
            if source.isExhausted {
                // The gapless join: the next track carries on in this same buffer.
                released.append(voice.sources.removeFirst())
                continue
            }
            if produced < count {
                stalled = true
                break
            }
        }
        if isCurrent {
            isStalled = stalled
            if stalled, let source = voice.sources.first {
                timeline.append(frame: writtenFrames + Int64(offset + produced), songID: source.song.id, position: source.position, step: 0)
            }
            if produced > 0, let spectrum {
                spectrum.sampleRate = Double(rate)
                spectrum.write(voiceLeft, count: produced)
            }
        }
        voice.mix(voiceLeft, voiceRight, produced: produced, count: count, into: mixLeft + offset, mixRight + offset)
    }

    // MARK: - Fades

    /// Where the planned fade starts, in the outgoing track's seconds: the beat it was
    /// matched to, or its fade point counted back from the end.
    private func trigger(of plan: FadePlan, in source: TrackSource) -> Double? {
        if let beats = plan.beats { return beats.start }
        let duration = source.duration
        guard duration > 0 else { return nil }
        return duration - plan.overlap
    }

    /// Frames of the active voice until its fade is due, so a buffer can be split there.
    private func framesUntilFade() -> Int? {
        guard let plan, incoming != nil, let active, let source = active.sources.first,
              source.song.id == plan.outgoingID, let trigger = trigger(of: plan, in: source)
        else { return nil }
        let seconds = (trigger - source.position) / max(active.tempo * speed, 0.1)
        return max(1, Int((seconds * Double(rate)).rounded(.up)))
    }

    /// Starts the planned fade if the active voice has reached it. True when it did.
    private func beginFadeIfDue() -> Bool {
        guard var plan, let incoming, let active, let source = active.sources.first,
              source.song.id == plan.outgoingID, let trigger = trigger(of: plan, in: source),
              source.position >= trigger - 0.5 / Double(rate)
        else { return false }

        if let beats = plan.beats {
            if let reason = beatMatchProblem(beats, outgoing: source, active: active, incoming: incoming) {
                // The plain fade goes ahead in its place, at its own point.
                notes.append("beat-matched start skipped: \(reason)")
                plan.beats = nil
                self.plan = plan
                return true
            }
        }

        let seconds: Double
        if let beats = plan.beats {
            seconds = max(beats.overlap / speed, SweetFades.minimumOverlap)
            incoming.tempo = beats.rate
            incoming.easeAfter = (delay: Int(seconds * Double(rate)), length: Int(beats.easeOut / speed * Double(rate)))
        } else {
            seconds = max(source.duration - source.position, SweetFades.minimumOverlap)
        }

        let length = max(1, Int(seconds * Double(rate)))
        active.fade(to: 0, over: length, curve: .equalPowerOut)
        incoming.gain = 0
        incoming.fade(to: 1, over: length, curve: .equalPowerIn)
        fading.append(active)
        self.active = incoming
        self.incoming = nil
        self.plan = nil
        return true
    }

    /// Why a beat-matched start cannot be made now, or nil when it can.
    private func beatMatchProblem(_ beats: BeatMatch.Plan, outgoing: TrackSource, active: Voice, incoming: Voice) -> String? {
        guard active.easeAfter == nil, active.tempo == 1 else {
            return "the outgoing track is still easing its tempo"
        }
        guard outgoing.knowsDuration, abs(outgoing.duration - beats.outgoingDuration) <= 0.5 else {
            return "the outgoing track is \(outgoing.duration) s here, \(beats.outgoingDuration) s analysed"
        }
        guard let next = incoming.sources.first, next.isReady, !next.didFail else {
            return "the incoming track is not ready"
        }
        return nil
    }

    // MARK: - Reading back (main actor, with `lock` held by the caller)

    /// What is heard at `frame`: the track, where in it, and whether it is moving.
    func heard(at frame: Int64) -> Timeline.Reading? {
        timeline.reading(at: frame)
    }
}

/// One player's worth of output: a track, the tracks that follow it gaplessly, and its
/// gain and tempo over time.
final class Voice {
    var sources: [TrackSource]
    var gain: Float = 1
    /// Speed relative to the mixer's: 1, except for a track beat-matched into.
    var tempo: Double = 1
    /// For a beat-matched track: frames until its tempo starts easing back to 1, and over
    /// how many frames.
    var easeAfter: (delay: Int, length: Int)?
    private var ramp: Ramp?
    private var ease: (from: Double, done: Int, length: Int)?

    enum Curve {
        case linear
        /// sin: the incoming side of an equal-power fade.
        case equalPowerIn
        /// cos: the outgoing side. A linear pair dips about 3 dB in the middle, which is
        /// heard as a hole in the transition.
        case equalPowerOut
    }

    private struct Ramp {
        let from: Float
        let to: Float
        let length: Int
        var done: Int
        let curve: Curve
    }

    init(sources: [TrackSource]) {
        self.sources = sources
    }

    /// Faded all the way out, or with nothing left to play.
    var isSilentForGood: Bool {
        sources.isEmpty || (ramp == nil && gain <= 0)
    }

    func fade(to target: Float, over frames: Int, curve: Curve) {
        ramp = Ramp(from: gain, to: target, length: max(1, frames), done: 0, curve: curve)
    }

    /// Advances the tempo ease by a buffer and returns the tempo to play it at.
    func advanceTempo(by frames: Int, rate: Int) -> Double {
        if var pending = easeAfter {
            pending.delay -= frames
            if pending.delay <= 0 {
                easeAfter = nil
                if tempo != 1 { ease = (tempo, 0, max(1, pending.length)) }
            } else {
                easeAfter = pending
            }
        }
        if var current = ease {
            current.done = min(current.done + frames, current.length)
            let fraction = Double(current.done) / Double(current.length)
            tempo = current.from + (1 - current.from) * fraction
            ease = current.done >= current.length ? nil : current
        }
        return tempo
    }

    /// Adds this voice's buffer into the mix at its gain, ramping where a fade is running.
    func mix(
        _ left: UnsafeMutablePointer<Float>,
        _ right: UnsafeMutablePointer<Float>,
        produced: Int,
        count: Int,
        into mixLeft: UnsafeMutablePointer<Float>,
        _ mixRight: UnsafeMutablePointer<Float>
    ) {
        guard var ramp else {
            if gain > 0 {
                for frame in 0..<produced {
                    mixLeft[frame] += left[frame] * gain
                    mixRight[frame] += right[frame] * gain
                }
            }
            return
        }
        for frame in 0..<count {
            ramp.done = min(ramp.done + 1, ramp.length)
            let fraction = Float(ramp.done) / Float(ramp.length)
            let shaped: Float
            switch ramp.curve {
            case .linear: shaped = fraction
            case .equalPowerIn: shaped = sin(fraction * .pi / 2)
            case .equalPowerOut: shaped = 1 - cos(fraction * .pi / 2)
            }
            gain = ramp.from + (ramp.to - ramp.from) * shaped
            if frame < produced {
                mixLeft[frame] += left[frame] * gain
                mixRight[frame] += right[frame] * gain
            }
        }
        self.ramp = ramp.done >= ramp.length ? nil : ramp
    }
}

/// A fade the main actor has planned: out of the active voice's current track, into the
/// incoming voice's first, overlapping by `overlap` seconds — or, with `beats`, starting
/// on the beat the plan names.
struct FadePlan: Equatable {
    let outgoingID: String
    let incomingID: String
    let overlap: Double
    var beats: BeatMatch.Plan?
}

/// What the mixer played, by output frame: which track, at what position, moving how
/// fast. Read against the stream's latency, it says what is being heard now.
///
/// A fixed ring, appended to on the render thread under the mixer's lock. A marker that
/// only continues the previous one in a straight line is not stored, so in steady play
/// there is one marker per track rather than one per buffer.
final class Timeline {
    struct Reading {
        let songID: String?
        let position: Double
        let isMoving: Bool
    }

    private struct Marker {
        var frame: Int64 = 0
        var songID: String?
        var position: Double = 0
        var step: Double = 0
    }

    private var markers = [Marker](repeating: Marker(), count: 1_024)
    private var count = 0
    private var head = 0

    func append(frame: Int64, songID: String?, position: Double, step: Double) {
        if count > 0 {
            let last = markers[(head - 1 + markers.count) % markers.count]
            let projected = last.position + Double(frame - last.frame) * last.step
            if last.songID == songID, abs(last.step - step) < 1e-12, abs(projected - position) < 0.002 {
                return
            }
        }
        markers[head] = Marker(frame: frame, songID: songID, position: position, step: step)
        head = (head + 1) % markers.count
        count = min(count + 1, markers.count)
    }

    func reading(at frame: Int64) -> Reading? {
        guard count > 0 else { return nil }
        // Newest first: the frame asked about is almost always within the last few.
        for back in 1...count {
            let marker = markers[(head - back + markers.count) % markers.count]
            if marker.frame <= frame || back == count {
                let elapsed = Double(max(0, frame - marker.frame)) * marker.step
                return Reading(songID: marker.songID, position: marker.position + elapsed, isMoving: marker.step > 0)
            }
        }
        return nil
    }

    func reset() {
        count = 0
        head = 0
    }
}
