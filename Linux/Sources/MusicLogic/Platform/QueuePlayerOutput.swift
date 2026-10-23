import Foundation

/// The one output on Linux, under the phone's name so `PlaybackController` uses it
/// unchanged: Sweet Fades, gapless runs and beat-matched starts, executed by `Mixer`.
///
/// The main-actor half. It keeps the window the controller described — the current track
/// and what follows — and turns it into what the mixer should play: the current track
/// with its gapless continuation as the **active** voice, and, when the current track
/// fades into the next, an **incoming** voice ready with that next track and a plan saying
/// where the fade starts. The phone's two `AVQueuePlayer`s become those two voices, and its
/// host-clock scheduling becomes a sample number the mixer counts to.
///
/// Whether a transition fades, and whether it is beat-matched, is asked of the controller
/// exactly as on the phone, through `transition` and `beatMatch`.
///
/// Time comes back the other way. Four times a second the mixer's timeline is read at the
/// frame being heard — what was written, less the stream's latency — so `elapsed`, the
/// track changes reported through `onAdvanced`, and the lock screen follow the speakers
/// rather than the buffer.
@MainActor
final class QueuePlayerOutput: AudioOutput {
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    private(set) var isBuffering = false

    var volume: Float = 1 {
        didSet { withMixer { $0.volume = volume } }
    }

    var rate: Float = 1 {
        didSet { withMixer { $0.speed = Double(rate) } }
    }

    var onAdvanced: ((String?) -> Void)?
    var onUnreachable: ((String) -> Void)?
    var onTick: ((Double, Bool) -> Void)?
    var locate: ((Song) -> MediaLocation?)?
    var makeChain: ((Song) -> DSPChain)?
    var transition: ((Song, Song) -> Double?)?
    /// Asked about a fade `transition` has decided on: a beat-matched start for it, or nil
    /// to leave it a plain fade.
    var beatMatch: ((Song, Song, Double) -> BeatMatch.Plan?)?

    private let pulse = PulseOutput.shared
    private let mixer: Mixer
    /// The current track and what follows, as the controller last described it.
    private var window: [Song] = []
    private var wantsToPlay = false
    /// The track last reported as heard, so a change is reported once.
    private var heardSongID: String?
    /// The held source last reported unreachable, so it is reported once. Weak rather than
    /// an `ObjectIdentifier`: the source made to retry it can reuse the old one's address.
    private weak var reportedUnreachable: TrackSource?
    private var ticker: Task<Void, Never>?

    /// How far ahead of needing it a track's decoder is started: enough to open a stream
    /// and fill its ring on a slow server, little enough that a long queue is not a pile
    /// of open connections.
    private static let startLead = 45.0

    init() {
        mixer = Mixer(rate: pulse.rate)
        let mixer = mixer
        pulse.render = { buffer, frames in mixer.render(into: buffer, frames: frames) }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.tick()
            }
        }
    }

    func setSpectrumSink(_ buffer: AudioSampleBuffer?) {
        guard let buffer else { return }
        withMixer { $0.spectrum = buffer }
    }

    var holdsCurrent: Bool {
        withMixer { mixer in mixer.active?.sources.first.map { !$0.didFail } ?? false }
    }

    private func withMixer<T>(_ body: (Mixer) -> T) -> T {
        mixer.lock.lock()
        defer { mixer.lock.unlock() }
        return body(mixer)
    }

    // MARK: - Loading

    func load(window songs: [Song], startAt: Double) {
        window = songs
        guard let current = songs.first, let first = makeSource(for: current) else {
            stop()
            if let current = songs.first {
                // Nothing to play it from. Reported as run off the end, so the controller
                // moves on rather than sitting on a silent track.
                heardSongID = current.id
                Task { @MainActor [weak self] in
                    self?.heardSongID = nil
                    self?.onAdvanced?(nil)
                }
            }
            return
        }
        if startAt > 0 { first.seek(to: startAt) }
        first.start()

        var released: [TrackSource] = []
        pulse.withRenderingHeld(flush: true) {
            withMixer { mixer in
                released = Self.allSources(of: mixer)
                mixer.active = Voice(sources: [first])
                mixer.incoming = nil
                mixer.fading = []
                mixer.plan = nil
                mixer.timeline.reset()
                mixer.timeline.append(frame: mixer.writtenFrames, songID: current.id, position: startAt, step: 0)
            }
        }
        released.forEach { $0.cancel() }

        heardSongID = current.id
        duration = Double(current.duration ?? 0)
        elapsed = startAt
        rebuildTail()
    }

    func updateUpcoming(_ songs: [Song]) {
        guard let current = window.first else { return }
        window = [current] + songs
        rebuildTail()
    }

    /// Re-asks every transition, for when the answer may have changed — the tracks either
    /// side of one were just measured, say, so a guessed fade can become a real one.
    func refreshTransitions() {
        rebuildTail()
    }

    /// A song's bytes moved — a stream finished caching — so anything waiting to play it is
    /// rebuilt from wherever `locate` now says. The track playing is left alone.
    func sourceChanged(for songID: String) {
        // Too close to the end: the next track is already buffered for its join, and the
        // stream plays fine.
        if duration > 0, duration - elapsed < 20 { return }

        var released: [TrackSource] = []
        withMixer { mixer in
            guard let active = mixer.active else { return }
            let waiting = active.sources.dropFirst() + (mixer.incoming?.sources ?? [])
            guard waiting.contains(where: { $0.song.id == songID }) else { return }
            released = Array(active.sources.dropFirst()) + (mixer.incoming?.sources ?? [])
            active.sources = Array(active.sources.prefix(1))
            mixer.incoming = nil
            mixer.plan = nil
        }
        guard !released.isEmpty else { return }
        released.forEach { $0.cancel() }
        rebuildTail()
    }

    /// Makes the mixer match the window: the active voice gets the current track's gapless
    /// continuation; if the current track fades into the next, the incoming voice is given
    /// that next track and its own continuation, and the fade is planned. Parts that already
    /// match are kept, so this is safe on every queue change.
    private func rebuildTail() {
        alignWindow()
        guard let current = window.first else { return }

        var fade: (song: Song, overlap: Double)?
        if window.count > 1, let overlap = transition?(current, window[1]) {
            fade = (window[1], overlap)
        }
        let beats = fade.flatMap { beatMatch?(current, $0.song, $0.overlap) }
        let desiredTail = fade == nil ? Array(gaplessRun(window).dropFirst()) : []
        let desiredIncoming = fade == nil ? [] : gaplessRun(Array(window.dropFirst()))

        let (presentTail, presentIncoming) = withMixer { mixer -> ([String], [String]) in
            (
                mixer.active?.sources.dropFirst().map(\.song.id) ?? [],
                mixer.incoming?.sources.map(\.song.id) ?? []
            )
        }

        // Sources are made outside the lock: making one asks the controller where its
        // bytes are, and allocates its ring.
        let keptTail = commonPrefix(presentTail, desiredTail.map(\.id))
        let newTail = desiredTail.dropFirst(keptTail).compactMap(makeSource)
        let keptIncoming = commonPrefix(presentIncoming, desiredIncoming.map(\.id))
        let newIncoming = desiredIncoming.dropFirst(keptIncoming).compactMap(makeSource)

        var released: [TrackSource] = []
        var applied = false
        withMixer { mixer in
            guard let active = mixer.active, active.sources.first?.song.id == current.id else { return }
            applied = true

            let tail = active.sources.dropFirst()
            released += tail.dropFirst(keptTail)
            active.sources = [active.sources[0]] + tail.prefix(keptTail) + newTail

            if desiredIncoming.isEmpty {
                released += mixer.incoming?.sources ?? []
                mixer.incoming = nil
            } else if let incoming = mixer.incoming, keptIncoming > 0 {
                released += incoming.sources.dropFirst(keptIncoming)
                incoming.sources = Array(incoming.sources.prefix(keptIncoming)) + newIncoming
            } else {
                released += mixer.incoming?.sources ?? []
                mixer.incoming = newIncoming.isEmpty ? nil : Voice(sources: newIncoming)
            }

            if let fade, let incoming = mixer.incoming, incoming.sources.first?.song.id == fade.song.id {
                mixer.plan = FadePlan(outgoingID: current.id, incomingID: fade.song.id, overlap: fade.overlap, beats: beats)
            } else {
                mixer.plan = nil
            }
        }
        if !applied { released = newTail + newIncoming }
        released.forEach { $0.cancel() }
        startAhead()
    }

    /// The mixer may have moved on — a gapless join, a fade — before the timeline says it
    /// has been heard. Planning starts from the track it is actually on.
    private func alignWindow() {
        let actual = withMixer { $0.active?.sources.first?.song.id }
        guard let actual, window.first?.id != actual,
              let index = window.firstIndex(where: { $0.id == actual })
        else { return }
        window.removeFirst(index)
    }

    /// The first song plus every following song reached without a fade.
    private func gaplessRun(_ songs: [Song]) -> [Song] {
        guard var previous = songs.first else { return [] }
        var run = [previous]
        for song in songs.dropFirst() {
            guard transition?(previous, song) == nil else { break }
            run.append(song)
            previous = song
        }
        return run
    }

    private func commonPrefix(_ present: [String], _ desired: [String]) -> Int {
        zip(present, desired).prefix { $0 == $1 }.count
    }

    private func makeSource(for song: Song) -> TrackSource? {
        guard let location = locate?(song) else { return nil }
        return TrackSource(song: song, location: location, rate: mixer.rate, chain: makeChain?(song))
    }

    private static func allSources(of mixer: Mixer) -> [TrackSource] {
        (mixer.active?.sources ?? []) + (mixer.incoming?.sources ?? [])
            + mixer.fading.flatMap(\.sources) + mixer.released
    }

    /// Starts the decoders of whatever plays next once it is near: the gapless follower
    /// and the track a fade brings in.
    private func startAhead() {
        let (current, follower, incoming, trigger) = withMixer { mixer -> (TrackSource?, TrackSource?, TrackSource?, Double?) in
            let active = mixer.active?.sources
            let trigger = mixer.plan.map { plan in plan.beats?.start ?? 0 }
            return (active?.first, active?.dropFirst().first, mixer.incoming?.sources.first, trigger)
        }
        guard let current else { return }
        current.start()
        let position = current.position
        let remaining = current.duration > 0 ? current.duration - position : 0
        if let follower, remaining < Self.startLead {
            follower.start()
        }
        if let incoming {
            // A beat-matched start is due at its beat; a plain fade, its overlap before the end.
            let due = trigger.map { $0 > 0 ? $0 - position : remaining } ?? remaining
            if due < Self.startLead { incoming.start() }
        }
    }

    // MARK: - Transport

    func play() {
        wantsToPlay = true
        startAhead()
        pulse.setPlaying(true)
    }

    func pause() {
        wantsToPlay = false
        pulse.setPlaying(false)
        // Finishing the fade rather than freezing it: a resume should not bring back a
        // track that was on its way out.
        var released: [TrackSource] = []
        pulse.withRenderingHeld {
            withMixer { mixer in
                released = mixer.fading.flatMap(\.sources)
                mixer.fading = []
                Self.settleTempo(mixer)
            }
        }
        released.forEach { $0.cancel() }
    }

    func seek(to seconds: Double) {
        var released: [TrackSource] = []
        pulse.withRenderingHeld(flush: true) {
            withMixer { mixer in
                released = mixer.fading.flatMap(\.sources)
                mixer.fading = []
                Self.settleTempo(mixer)
                guard let source = mixer.active?.sources.first else { return }
                source.seek(to: seconds)
                mixer.timeline.reset()
                mixer.timeline.append(frame: mixer.writtenFrames, songID: source.song.id, position: seconds, step: 0)
            }
        }
        released.forEach { $0.cancel() }
        elapsed = seconds
    }

    func stop() {
        wantsToPlay = false
        pulse.setPlaying(false)
        var released: [TrackSource] = []
        pulse.withRenderingHeld(flush: true) {
            withMixer { mixer in
                released = Self.allSources(of: mixer)
                mixer.active = nil
                mixer.incoming = nil
                mixer.fading = []
                mixer.plan = nil
                mixer.released = []
                mixer.timeline.reset()
            }
        }
        released.forEach { $0.cancel() }
        window = []
        heardSongID = nil
        elapsed = 0
        duration = 0
        isBuffering = false
    }

    /// Every track back to its own tempo at once: for a seek, a pause, or anything else
    /// that ends the matched part of a transition early.
    private static func settleTempo(_ mixer: Mixer) {
        for voice in [mixer.active, mixer.incoming].compactMap({ $0 }) {
            voice.tempo = 1
            voice.easeAfter = nil
        }
    }

    // MARK: - Time

    private func tick() {
        let latency = pulse.latency()
        let snapshot = withMixer { mixer in
            let heard = mixer.heard(at: mixer.writtenFrames - Int64(latency * Double(mixer.rate)))
            let notes = mixer.notes
            let released = mixer.released
            mixer.notes.removeAll(keepingCapacity: true)
            mixer.released.removeAll(keepingCapacity: true)
            let current = mixer.active?.sources.first
            return (heard, notes, released, current)
        }
        let (heard, notes, released, current) = snapshot
        released.forEach { $0.cancel() }
        for note in notes {
            Task { await Diagnostics.shared.record("fades", note) }
        }
        startAhead()

        guard let heard else { return }
        if heard.songID != heardSongID {
            heardSongID = heard.songID
            if let songID = heard.songID, let position = window.firstIndex(where: { $0.id == songID }) {
                window.removeFirst(position)
            }
            duration = current?.song.id == heard.songID ? current?.duration ?? 0 : Double(window.first?.duration ?? 0)
            elapsed = heard.position
            onAdvanced?(heard.songID)
            // A step moves the window, so the next transition needs planning.
            rebuildTail()
            return
        }

        guard heard.songID != nil else {
            // Nothing loaded is not buffering, whatever was asked for.
            isBuffering = false
            return
        }
        let moved = abs(heard.position - elapsed) > 0.0001
        elapsed = heard.position
        if let current, current.song.id == heard.songID {
            let known = current.duration
            if known > 0 { duration = known }
        }
        isBuffering = wantsToPlay && !heard.isMoving
        if wantsToPlay || moved {
            onTick?(elapsed, wantsToPlay && heard.isMoving)
        }

        // Reported once what is heard has reached the held track, so the controller is
        // never told about a track it has not yet been told is playing.
        if let current, current.song.id == heard.songID, current.isUnreachable,
           reportedUnreachable !== current {
            reportedUnreachable = current
            onUnreachable?(current.song.id)
        }
    }
}
