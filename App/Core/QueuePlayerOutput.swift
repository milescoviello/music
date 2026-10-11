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

        for player in players {
            player.pause()
            player.removeAllItems()
        }
        itemToSongID.removeAll()
        tapContexts.removeAll()
        readyItems.removeAll()
        plannedFade = nil
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
        for player in players { player.pause() }
    }

    func seek(to seconds: Double) {
        if isFading { completeFade() }

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
        for player in players {
            player.defaultRate = rate
            if player.rate != 0 { player.rate = rate }
        }
    }

    // MARK: - Sweet Fades

    /// Starts the planned fade once the current track is within its overlap of the end.
    private func beginFadeIfDue() {
        guard let plan = plannedFade, !isFading, wantsToPlay, duration > 0 else { return }

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

    private func startFade(over seconds: Double) {
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
        players[incoming].defaultRate = rate
        players[incoming].play()

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
            self?.completeFade()
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

        // The idle player is free again, so the next fade can be prepared.
        rebuildTail(includingCurrent: false)
    }

    private func cancelFade() {
        fadeTask?.cancel()
        fadeTask = nil
        fadingIndex = nil
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
