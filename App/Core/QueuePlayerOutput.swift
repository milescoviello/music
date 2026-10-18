import AVFoundation
import Foundation

/// The one output: two `AVQueuePlayer`s, Plexamp's processing chain on every item, and
/// Sweet Fades between them.
///
/// `AVQueuePlayer` is kept because it handles the hard cases correctly for free —
/// streaming with byte-range seeking, network stalls, interruptions, route changes — and
/// because preloading the next item is what makes an album genuinely gapless. What it
/// cannot do alone is overlap two tracks, so there are two, used symmetrically:
///
/// - The **active** player carries the current track and every track after it that
///   follows gaplessly — in practice, the rest of an album played in order.
/// - The **idle** player is either empty, or preloaded with the track a fade is about to
///   start, or — for up to fifteen seconds — fading out the track before.
///
/// When the current track reaches its fade point the roles swap: the idle player starts
/// at zero volume and becomes the active one, the old one ramps down under it and is
/// emptied. So a fade costs one more player and no extra buffering, and a gapless run
/// never involves the second player at all.
///
/// Whether a transition fades, and for how long, is not decided here: `transition` asks
/// the controller, which applies Sweet Fades' rules. This type only executes the answer.
///
/// The same goes for a beat-matched fade, which `beatMatch` may make of one: the plan says
/// exactly when the incoming track starts and how fast, and executing it is the part that
/// has to be precise. The incoming player is prerolled and told to start at a host-clock
/// time, the moment the outgoing item's own timebase says its playhead reaches the planned
/// position — sample-accurate, where waiting for a tick and calling `play()` would be off
/// by tens of milliseconds and audibly flam. Anything that would make that start late or
/// wrong — the item not ready, a stall, a seek past it — leaves the plain fade to go ahead.
@MainActor
final class QueuePlayerOutput: AudioOutput {
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    private(set) var isBuffering = false

    var volume: Float = 1 {
        didSet { applyVolumes() }
    }

    var rate: Float = 1 {
        didSet { applyRate() }
    }

    var onAdvanced: ((String?) -> Void)?
    var onTick: ((Double, Bool) -> Void)?
    var locate: ((Song) -> MediaLocation?)?
    var makeChain: ((Song) -> DSPChain)?
    var transition: ((Song, Song) -> Double?)?
    /// Asked about a fade `transition` has decided on: a beat-matched start for it, or nil
    /// to leave it a plain fade.
    var beatMatch: ((Song, Song, Double) -> BeatMatch.Plan?)?

    private let players = [AVQueuePlayer(), AVQueuePlayer()]
    private var active = 0
    private var idle: Int { 1 - active }
    /// Crossfade gain per player, multiplied with `volume`.
    private var fadeGain: [Float] = [1, 1]

    /// `AVPlayerItem` is single-use, so these map live items back to songs and taps.
    private var itemToSongID: [ObjectIdentifier: String] = [:]
    private var tapContexts: [ObjectIdentifier: AudioTap.Context] = [:]
    /// Items whose tap is attached, or definitely will not be. Only these may start:
    /// a track that begins unprocessed and then jumps by its ReplayGain is worse than
    /// one that starts a moment later.
    private var readyItems: Set<ObjectIdentifier> = []
    private var expectedItem: AVPlayerItem?

    /// The current track and what follows, as the controller last described it.
    private var window: [Song] = []
    /// Set when the *current* transition is a fade: the song it starts, and how long it
    /// overlaps. The idle player holds that song, ready.
    private var plannedFade: (song: Song, overlap: Double)?
    private var fadeTask: Task<Void, Never>?
    private var fadingIndex: Int?
    private var isFading: Bool { fadingIndex != nil }

    /// Set alongside `plannedFade` when that fade is also beat-matched: exactly when the
    /// incoming track starts, and how fast. Never instead of it — a start that cannot be
    /// lined up when it is due leaves the plain fade to go ahead.
    private var plannedBeats: BeatMatch.Plan?
    /// A beat-matched start the incoming player is being prepared for, or has been told to
    /// make and has not made yet.
    private var cue: Cue?
    private var cueCount = 0
    /// Each player's speed relative to `rate`: 1, except for a track beat-matched into,
    /// which plays at the outgoing track's tempo through the overlap and eases back after.
    private var tempo: [Float] = [1, 1]
    private var easeTask: Task<Void, Never>?

    private struct Cue {
        let id: Int
        let plan: BeatMatch.Plan
        /// Wakes when the incoming track starts, to hand the fade over to it.
        var handover: Task<Void, Never>?
    }

    /// How far ahead of a beat-matched start the incoming player is prerolled and given its
    /// start time. Ticks come four times a second, so in practice 1.75 to 2 seconds.
    private static let cueLead = 2.0
    /// Less notice than this and the start could come late, which is worse than a plain fade.
    private static let minimumCueNotice = 0.15
    /// How far the two tracks' playheads may disagree, once started, before the start is
    /// recorded as having missed — the size of a flam.
    private static let syncTolerance = 0.010

    private var wantsToPlay = false
    private var startFallback: Task<Void, Never>?
    private var spectrum: AudioSampleBuffer?
    /// Never removed: each observer is owned by its player, which is owned by this
    /// object, so they are deallocated together.
    private var timeObservers: [Any] = []

    init() {
        for player in players {
            player.actionAtItemEnd = .advance
        }
        addTimeObservers()
    }

    /// Feeds the visualiser from every item made after this, which in practice is every
    /// item: the controller sets it before anything is loaded.
    func setSpectrumSink(_ buffer: AudioSampleBuffer?) {
        guard let buffer, spectrum == nil else { return }
        spectrum = buffer
    }

    // MARK: - Loading

    func load(window songs: [Song], startAt: Double) {
        resetPlayers()
        window = songs

        guard let current = songs.first else {
            duration = 0
            elapsed = 0
            return
        }

        rebuildTail(includingCurrent: true)

        expectedItem = players[active].currentItem
        duration = Double(current.duration ?? 0)
        elapsed = startAt

        if startAt > 0 { seek(to: startAt) }
    }

    func updateUpcoming(_ songs: [Song]) {
        guard let current = window.first else { return }
        window = [current] + songs
        rebuildTail(includingCurrent: false)
    }

    /// Re-asks every transition, for when the answer may have changed — the tracks
    /// either side of one were just measured, say, so a guessed fade can become a real one.
    func refreshTransitions() {
        rebuildTail(includingCurrent: false)
    }

    /// A song's bytes moved — a stream finished caching, say — so any item for it that
    /// has not started is rebuilt from wherever `locate` now says. The track playing is
    /// left alone: swapping it would be a seek, and an audible one.
    func sourceChanged(for songID: String) {
        // Too close to the end, the next item is already being buffered for a gapless
        // start, and swapping it now would cost the boundary. The stream plays fine.
        if duration > 0, duration - elapsed < 20 { return }

        let activePlayer = players[active]
        let idlePlayer = players[idle]
        let waiting = Array(activePlayer.items().dropFirst()) + (isFading ? [] : idlePlayer.items())
        guard waiting.contains(where: { itemToSongID[ObjectIdentifier($0)] == songID }) else { return }

        for item in activePlayer.items().dropFirst() {
            discard(item, from: activePlayer)
        }
        if !isFading {
            cancelCue()
            idlePlayer.pause()
            for item in idlePlayer.items() {
                discard(item, from: idlePlayer)
            }
        }
        rebuildTail(includingCurrent: false)
    }

    /// Makes the players match the window.
    ///
    /// The active player gets the current track and its gapless continuation; if the
    /// current track fades into the next, the idle player is given that next track (and
    /// its own continuation) to start from. Each part is rebuilt only when it differs
    /// from what is already loaded, so this is safe to call on every queue change.
    private func rebuildTail(includingCurrent: Bool) {
        guard let current = window.first else { return }

        var fade: (song: Song, overlap: Double)?
        if window.count > 1, let overlap = transition?(current, window[1]) {
            fade = (window[1], overlap)
        }
        plannedFade = fade
        let beats = fade.flatMap { beatMatch?(current, $0.song, $0.overlap) }
        if let cue, cue.plan != beats { cancelCue() }
        plannedBeats = beats

        let activePlayer = players[active]
        if includingCurrent {
            fill(activePlayer, with: [current])
        }

        let desiredTail = fade == nil ? Array(gaplessRun(window).dropFirst()) : []
        let presentTail = activePlayer.items().dropFirst().compactMap { itemToSongID[ObjectIdentifier($0)] }
        if presentTail != desiredTail.map(\.id) {
            for item in activePlayer.items().dropFirst() {
                discard(item, from: activePlayer)
            }
            fill(activePlayer, with: desiredTail)
        }

        // While a fade is running the idle player is the one fading out; the next fade
        // can only be prepared once it is free.
        guard !isFading else { return }

        let idlePlayer = players[idle]
        let desiredIdle = fade == nil ? [] : gaplessRun(Array(window.dropFirst()))
        let presentIdle = idlePlayer.items().compactMap { itemToSongID[ObjectIdentifier($0)] }
        if presentIdle != desiredIdle.map(\.id) {
            idlePlayer.pause()
            for item in idlePlayer.items() {
                discard(item, from: idlePlayer)
            }
            fill(idlePlayer, with: desiredIdle)
        }
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

    private func fill(_ player: AVQueuePlayer, with songs: [Song]) {
        for song in songs {
            guard let item = makeItem(for: song), player.canInsert(item, after: nil) else { continue }
            player.insert(item, after: nil)
        }
    }

    private func discard(_ item: AVPlayerItem, from player: AVQueuePlayer) {
        let id = ObjectIdentifier(item)
        itemToSongID[id] = nil
        tapContexts[id] = nil
        readyItems.remove(id)
        player.remove(item)
    }

    private func resetPlayers() {
        cancelFade()
        startFallback?.cancel()
        startFallback = nil
        wantsToPlay = false
        cue?.handover?.cancel()
        cue = nil
        easeTask?.cancel()
        easeTask = nil
        tempo = [1, 1]

        for player in players {
            player.pause()
            player.removeAllItems()
            player.automaticallyWaitsToMinimizeStalling = true
            player.defaultRate = rate
        }
        itemToSongID.removeAll()
        tapContexts.removeAll()
        readyItems.removeAll()
        plannedFade = nil
        plannedBeats = nil
        expectedItem = nil
        active = 0
        fadeGain = [1, 1]
        applyVolumes()
    }

    // MARK: - Items

    private func makeItem(for song: Song) -> AVPlayerItem? {
        guard let location = locate?(song) else { return nil }

        var options: [String: Any] = [:]
        if !location.isLocal, let mime = location.mimeType {
            options[AVURLAssetOverrideMIMETypeKey] = mime
        }

        let asset = AVURLAsset(url: location.url, options: options)
        let item = AVPlayerItem(asset: asset)
        // Speed changes keep the pitch. Spectral is the algorithm meant for music.
        item.audioTimePitchAlgorithm = .spectral
        let id = ObjectIdentifier(item)
        itemToSongID[id] = song.id

        if let chain = makeChain?(song) {
            Task { await attachTap(to: item, chain: chain) }
        } else {
            readyItems.insert(id)
        }
        return item
    }

    /// Attaches the processing tap. Loading the track is async — over the network it is
    /// the header fetch the player needed anyway — which is why items are not started
    /// until this has run.
    private func attachTap(to item: AVPlayerItem, chain: DSPChain) async {
        let track = try? await item.asset.loadTracks(withMediaType: .audio).first
        let id = ObjectIdentifier(item)
        // Discarded while loading: a skip, a queue edit.
        guard itemToSongID[id] != nil else { return }

        if let track, let made = AudioTap.makeMix(for: track, chain: chain, spectrum: spectrum) {
            item.audioMix = made.mix
            tapContexts[id] = made.context
        }
        readyItems.insert(id)

        if players[active].currentItem === item {
            startIfReady()
        }
    }

    // MARK: - Transport

    func play() {
        wantsToPlay = true
        startIfReady()
    }

    /// Starts the active player once its current item is ready, or after a second and a
    /// half regardless — a tap that never attaches must cost the processing, never the
    /// music.
    private func startIfReady() {
        guard wantsToPlay else { return }
        let player = players[active]

        if let item = player.currentItem, !readyItems.contains(ObjectIdentifier(item)) {
            guard startFallback == nil else { return }
            startFallback = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, !Task.isCancelled else { return }
                startFallback = nil
                if let item = players[active].currentItem {
                    readyItems.insert(ObjectIdentifier(item))
                }
                startIfReady()
            }
            return
        }

        startFallback?.cancel()
        startFallback = nil
        player.defaultRate = rate
        player.play()
    }

    func pause() {
        wantsToPlay = false
        // Finishing the fade rather than freezing it: a resume should not bring back a
        // track that was on its way out.
        if isFading { completeFade() }
        cancelCue()
        settleTempo()
        for player in players { player.pause() }
    }

    func seek(to seconds: Double) {
        if isFading { completeFade() }
        // Lined up for where the track was; the next tick lines it up again if there is
        // still time.
        cancelCue()
        settleTempo()

        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        // Hops rather than asserting: unlike the periodic time observer, which is
        // explicitly given the main queue, a seek completion carries no such promise.
        players[active].seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.elapsed = seconds
            }
        }
        elapsed = seconds
    }

    func stop() {
        resetPlayers()
        window = []
        elapsed = 0
        duration = 0
    }

    private func applyVolumes() {
        for (index, player) in players.enumerated() {
            player.volume = volume * fadeGain[index]
        }
    }

    private func applyRate() {
        // A start lined up at the old speed would land at the wrong moment; the next tick
        // lines it up again at the new one.
        cancelCue()
        for (index, player) in players.enumerated() {
            player.defaultRate = rate * tempo[index]
            if player.rate != 0 { player.rate = rate * tempo[index] }
        }
    }

    // MARK: - Sweet Fades

    /// Starts the planned fade once the current track is within its overlap of the end.
    private func beginFadeIfDue() {
        guard let plan = plannedFade, !isFading, wantsToPlay, duration > 0 else { return }

        // A beat-matched start waits for its own moment, which may be before or after the
        // plain fade's; the plain fade only goes ahead once it cannot happen.
        if let beats = plannedBeats {
            if cue != nil {
                // A stall now would leave the incoming track starting on time against an
                // outgoing one that is late.
                if players[active].timeControlStatus != .playing { abandonCue("the outgoing track stalled") }
                return
            }
            if cueIfDue(beats, song: plan.song) { return }
            plannedBeats = nil
        }

        let remaining = duration - elapsed
        guard remaining <= plan.overlap else { return }

        let incoming = players[idle]
        guard let first = incoming.currentItem,
              itemToSongID[ObjectIdentifier(first)] == plan.song.id,
              first.status != .failed
        else {
            // The track to fade into is not there to play. Let the current one finish and
            // the controller decide, rather than fading into silence.
            plannedFade = nil
            return
        }

        startFade(over: max(remaining, SweetFades.minimumOverlap))
    }

    /// `beats` for a beat-matched fade, whose incoming track has already started on its
    /// own, at its own speed; it eases back to its own tempo once the fade is over.
    private func startFade(over seconds: Double, beats: BeatMatch.Plan? = nil) {
        let outgoing = active
        let incoming = idle

        plannedFade = nil
        fadingIndex = outgoing
        active = incoming

        // The visualiser follows the incoming track from its first sample.
        if let item = players[outgoing].currentItem {
            tapContexts[ObjectIdentifier(item)]?.feedsSpectrum.store(false, ordering: .relaxed)
        }

        fadeGain[incoming] = 0
        applyVolumes()
        if beats == nil {
            players[incoming].defaultRate = rate
            players[incoming].play()
        }

        // The current track changes now, at the start of the overlap: that is when the
        // next song is the one being heard arrive, and the lock screen and the play count
        // should say so.
        if !window.isEmpty { window.removeFirst() }
        expectedItem = players[incoming].currentItem
        duration = Double(window.first?.duration ?? 0)
        elapsed = 0

        fadeTask = Task { [weak self] in
            let steps = max(1, Int(seconds * 30))
            for step in 1...steps {
                try? await Task.sleep(for: .seconds(seconds / Double(steps)))
                guard let self, !Task.isCancelled else { return }
                // Equal power: a linear pair dips ~3 dB in the middle, which is audible as
                // a hole in the transition.
                let fraction = Float(step) / Float(steps)
                fadeGain[incoming] = sin(fraction * .pi / 2)
                fadeGain[outgoing] = cos(fraction * .pi / 2)
                applyVolumes()
            }
            guard let self else { return }
            completeFade()
            if let beats { easeTempo(of: incoming, over: beats.easeOut / Double(rate)) }
        }

        onAdvanced?(window.first?.id)
    }

    /// Ends a fade now, whether it ran its course or was interrupted.
    private func completeFade() {
        fadeTask?.cancel()
        fadeTask = nil
        guard let outgoing = fadingIndex else { return }
        fadingIndex = nil

        let player = players[outgoing]
        player.pause()
        for item in player.items() {
            discard(item, from: player)
        }
        fadeGain = [1, 1]
        applyVolumes()
        // A track beat-matched into traded waiting out a stall for starting on time; with
        // the overlap over, it goes back to waiting.
        players[active].automaticallyWaitsToMinimizeStalling = true

        // The idle player is free again, so the next fade can be prepared.
        rebuildTail(includingCurrent: false)
    }

    private func cancelFade() {
        fadeTask?.cancel()
        fadeTask = nil
        fadingIndex = nil
    }

    // MARK: - Beat-matched fades

    /// Prepares the incoming player for a beat-matched start once it is near. True while
    /// that start is still on — not near yet, or now being prepared — and false when it
    /// cannot happen and the plain fade should go ahead instead.
    private func cueIfDue(_ beats: BeatMatch.Plan, song: Song) -> Bool {
        let outgoing = players[active]
        guard rate > 0, let timebase = outgoing.currentItem?.timebase else { return false }
        let position = CMTimebaseGetTime(timebase).seconds
        guard position.isFinite else { return false }
        // Real seconds until the start, at whatever speed the player is set to.
        let notice = (beats.start - position) / Double(rate)
        if notice > Self.cueLead { return true }
        // Past it already: a seek landed inside the overlap.
        guard notice > Self.minimumCueNotice else { return false }

        let incoming = players[idle]
        guard abs(duration - beats.outgoingDuration) <= 0.5 else {
            // Measured on a different file, or one whose length the player reads
            // differently: its beat times cannot be trusted against this item.
            return skip("the outgoing track is \(duration) s here, \(beats.outgoingDuration) s analysed")
        }
        guard outgoing.timeControlStatus == .playing else { return skip("the outgoing track is not playing") }
        guard incoming.status == .readyToPlay,
              let item = incoming.currentItem,
              itemToSongID[ObjectIdentifier(item)] == song.id,
              item.status == .readyToPlay,
              readyItems.contains(ObjectIdentifier(item))
        else { return skip("the incoming track is not ready") }

        cueCount += 1
        let id = cueCount
        cue = Cue(id: id, plan: beats)
        // Silent until the fade raises it: it starts by itself, a moment before the handover.
        fadeGain[idle] = 0
        applyVolumes()
        // Required for a start at a host time, and the price of one: a stall during the
        // overlap stutters rather than waits. Prerolling first is what makes one unlikely.
        incoming.automaticallyWaitsToMinimizeStalling = false
        incoming.preroll(atRate: rate * Float(beats.rate)) { [weak self] finished in
            Task { @MainActor in self?.prerolled(finished, cue: id) }
        }
        return true
    }

    /// The incoming player is primed. It is told to start, from the top and at its matched
    /// speed, at the host-clock time when the outgoing item's playhead reaches the planned
    /// start — read from that item's own timebase, so the two meet to the sample rather
    /// than to the nearest tick.
    private func prerolled(_ finished: Bool, cue id: Int) {
        guard let cue, cue.id == id else { return }
        let outgoing = players[active]
        let incoming = players[idle]
        guard finished, wantsToPlay, outgoing.timeControlStatus == .playing,
              let timebase = outgoing.currentItem?.timebase,
              incoming.currentItem != nil
        else { return abandonCue("the incoming track could not be prerolled") }

        let hostClock = CMClockGetHostTimeClock()
        let start = CMSyncConvertTime(
            CMTime(seconds: cue.plan.start, preferredTimescale: 1_000_000_000),
            from: timebase,
            to: hostClock
        )
        let notice = CMTimeSubtract(start, CMClockGetTime(hostClock)).seconds
        guard start.isNumeric, notice > Self.minimumCueNotice else {
            return abandonCue("prerolling took too long")
        }

        let plan = cue.plan
        tempo[idle] = Float(plan.rate)
        incoming.setRate(rate * tempo[idle], time: .zero, atHostTime: start)
        self.cue?.handover = Task { [weak self] in
            try? await Task.sleep(for: .seconds(notice))
            guard let self, !Task.isCancelled, self.cue?.id == id else { return }
            handOver(plan)
        }
    }

    /// The incoming track has just started, on time and at its matched speed: the fade,
    /// and the change of track, begin now.
    private func handOver(_ beats: BeatMatch.Plan) {
        cue = nil
        plannedBeats = nil
        players[idle].defaultRate = rate * tempo[idle]
        startFade(over: max(beats.overlap / Double(rate), SweetFades.minimumOverlap), beats: beats)

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.5))
            self?.checkSync(beats)
        }
    }

    /// Half a second in, whether the incoming track really did start when it was told to:
    /// the two playheads, read together, against where the plan puts them. Only recorded —
    /// a correction now would be a jump in the music, which is worse than a flam — but it
    /// is the one way to know, on the phone, that the timing holds.
    private func checkSync(_ beats: BeatMatch.Plan) {
        guard let outgoing = fadingIndex,
              let outgoingTimebase = players[outgoing].currentItem?.timebase,
              let incomingTimebase = players[active].currentItem?.timebase
        else { return }
        let elapsedOut = CMTimebaseGetTime(outgoingTimebase).seconds - beats.start
        let elapsedIn = CMTimebaseGetTime(incomingTimebase).seconds / beats.rate
        // In the outgoing track's seconds: positive when the incoming one is behind.
        let late = elapsedOut - elapsedIn
        guard late.isFinite, abs(late) > Self.syncTolerance else { return }
        let milliseconds = Int((abs(late) * 1000).rounded())
        Task { await Diagnostics.shared.record("fades", "beat-matched start \(late > 0 ? "late" : "early") by \(milliseconds) ms") }
    }

    /// Undoes a cue that has not been handed over: the incoming player paused, silent no
    /// longer, and back at the top. The plan stays, so the next tick can line it up again
    /// if there is still time.
    private func cancelCue() {
        guard let cue else { return }
        cue.handover?.cancel()
        self.cue = nil

        let player = players[idle]
        player.pause()
        player.automaticallyWaitsToMinimizeStalling = true
        tempo[idle] = 1
        player.defaultRate = rate
        // Prerolling, or a start that had already begun, may have moved it on.
        if let item = player.currentItem, item.currentTime() != .zero {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        fadeGain[idle] = 1
        applyVolumes()
    }

    /// A cue that cannot be made after all: the plan is dropped and the plain fade goes
    /// ahead in its place.
    private func abandonCue(_ reason: String) {
        cancelCue()
        plannedBeats = nil
        Task { await Diagnostics.shared.record("fades", "beat-matched start abandoned: \(reason)") }
    }

    /// A beat-matched start that is due and cannot be made, recorded; false, for the plain
    /// fade to go ahead.
    private func skip(_ reason: String) -> Bool {
        Task { await Diagnostics.shared.record("fades", "beat-matched start skipped: \(reason)") }
        return false
    }

    /// Brings a track beat-matched into back to its own tempo once the track it was matched
    /// to has gone: ten steps a second, so the change is a drift rather than a lurch.
    private func easeTempo(of index: Int, over seconds: Double) {
        easeTask?.cancel()
        let from = tempo[index]
        guard from != 1 else { return }
        easeTask = Task { [weak self] in
            let steps = max(1, Int(seconds * 10))
            for step in 1...steps {
                try? await Task.sleep(for: .seconds(seconds / Double(steps)))
                guard let self, !Task.isCancelled else { return }
                setTempo(from + (1 - from) * Float(step) / Float(steps), of: index)
            }
        }
    }

    private func setTempo(_ value: Float, of index: Int) {
        tempo[index] = value
        let player = players[index]
        player.defaultRate = rate * value
        if player.rate != 0 { player.rate = rate * value }
    }

    /// Every track back to its own tempo at once: for a seek, a pause, or anything else that
    /// ends the matched part of a transition early.
    private func settleTempo() {
        easeTask?.cancel()
        easeTask = nil
        for index in players.indices where tempo[index] != 1 {
            setTempo(1, of: index)
        }
    }

    // MARK: - Time

    private func addTimeObservers() {
        // 4 Hz: enough for a smooth scrubber, and cheap. Item advancement is detected
        // here by identity rather than by KVO, which would arrive on an internal queue
        // and need an unsafe hop under strict concurrency.
        let interval = CMTime(value: 1, timescale: 4)
        for index in players.indices {
            let observer = players[index].addPeriodicTimeObserver(
                forInterval: interval,
                queue: .main
            ) { [weak self] time in
                MainActor.assumeIsolated {
                    self?.tick(player: index, time: time)
                }
            }
            timeObservers.append(observer)
        }
    }

    private func tick(player index: Int, time: CMTime) {
        // The player fading out ticks too, and has nothing to say.
        guard index == active else { return }
        let player = players[active]

        if player.currentItem !== expectedItem {
            expectedItem = player.currentItem
            // A track beat-matched into is over, however short it was.
            settleTempo()
            let songID = player.currentItem.flatMap { itemToSongID[ObjectIdentifier($0)] }

            if let songID, let position = window.firstIndex(where: { $0.id == songID }) {
                window.removeFirst(position)
            }
            duration = Double(window.first?.duration ?? 0)
            elapsed = 0
            onAdvanced?(songID)
            // A gapless step moves the window, so the next transition needs planning.
            rebuildTail(includingCurrent: false)
            return
        }

        elapsed = time.seconds.isFinite ? time.seconds : 0
        isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate

        if let itemDuration = player.currentItem?.duration.seconds,
           itemDuration.isFinite, itemDuration > 0 {
            duration = itemDuration
        }

        onTick?(elapsed, player.timeControlStatus == .playing)
        beginFadeIfDue()
    }
}
