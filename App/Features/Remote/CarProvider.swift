import Accelerate
import AVFoundation
import UIKit

/// What the phone serves the car that only the app itself can (`RemoteCarProvider`): covers
/// and their colours, the spectrum, lyrics as the lyrics screen has them, and the library.
/// The car (an Audi MMI 3G+) follows the phone as a remote on its own Wi-Fi and can reach
/// nothing else, so everything it shows comes through here.
@MainActor
final class CarProvider: RemoteCarProvider {
    private unowned let app: AppState
    private let analyser = CarSpectrumAnalyser()

    init(app: AppState) {
        self.app = app
    }

    // MARK: - Covers

    /// The cover filling `size`×`size` (a non-square one cropped to its middle), as RGB.
    func art(coverArt: String, size: Int) async -> Data? {
        let source: ArtworkStore.Size = size <= 160 ? .thumb : size <= 512 ? .card : .full
        guard let image = await app.artwork.image(for: coverArt, size: source), let cgImage = image.cgImage else { return nil }
        let rowBytes = size * 4
        var rgba = [UInt8](repeating: 0, count: size * rowBytes)
        let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: rowBytes,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            let width = CGFloat(cgImage.width), height = CGFloat(cgImage.height)
            let scale = CGFloat(size) / min(width, height)
            context.draw(cgImage, in: CGRect(
                x: (CGFloat(size) - width * scale) / 2, y: (CGFloat(size) - height * scale) / 2,
                width: width * scale, height: height * scale
            ))
            return true
        }
        guard drawn else { return nil }
        var rgb = Data(count: size * size * 3)
        rgb.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt8.self)
            for pixel in 0..<(size * size) {
                out[pixel * 3] = rgba[pixel * 4]
                out[pixel * 3 + 1] = rgba[pixel * 4 + 1]
                out[pixel * 3 + 2] = rgba[pixel * 4 + 2]
            }
        }
        return rgb
    }

    /// The colours the player takes from the cover, exactly: `CoverColours.pick`'s pools and
    /// `CoverTint`'s accent, so the car's screen is the phone's.
    func palette(coverArt: String) async -> RemoteCarPalette? {
        guard let colours = await VisualizerArtworkPalette.colours(for: coverArt, artwork: app.artwork) else { return nil }
        let pools = CoverColours.pick(colours)
        func bytes(_ r: Double, _ g: Double, _ b: Double) -> [Int] {
            [r, g, b].map { Int(min(max($0.rounded(), 0), 255)) }
        }
        let accent = CoverColours.accent(from: pools, lightness: 0.62).map { bytes($0.r * 255, $0.g * 255, $0.b * 255) }
        let poolBytes = pools.map { bytes($0.r, $0.g, $0.b) }
        return RemoteCarPalette(
            pools: poolBytes,
            accent: accent ?? poolBytes.first ?? [250, 71, 92],
            background: app.playerSettings.background.rawValue
        )
    }

    // MARK: - Lyrics

    /// The lines the lyrics screen would show: the set it picks, its offset applied, with the
    /// kept word timing, translation and romanization where the song has them.
    func lyrics(songID: String) async -> RemoteCarLyrics? {
        var sets = await LyricsStore.shared.load(songID: songID)
        if sets == nil { sets = try? await app.client.lyrics(songID: songID) }
        guard let sets, let shown = LyricsStore.shown(from: sets), !shown.lines.isEmpty else { return nil }
        let offset = shown.synced ? (shown.offset ?? 0) : 0
        let texts = shown.lines.map(\.value)
        let wordLines = shown.synced ? await LyricsStore.shared.words(songID: songID) : nil
        let translations = await LyricTranslationStore.shared.translations(songID: songID, lines: texts)
        let tag = shown.lang
        // Off the main actor, as the lyrics screen does it: tokenizing Japanese takes a while.
        let romanized = await Task.detached(priority: .userInitiated) {
            Romanizer.romanize(texts, language: LyricsLanguage.detect(texts, tag: tag))
        }.value

        let starts = shown.lines.map { $0.start.map { max(0, $0 - offset) } }
        var lines: [RemoteCarLyrics.Line] = []
        for (index, text) in texts.enumerated() {
            let start = starts[index]
            let end = starts.dropFirst(index + 1).compactMap { $0 }.first
            // Word timing comes from another source than the lines: matched by time.
            let words = start.flatMap { start in
                wordLines?.min { abs($0.start - start) < abs($1.start - start) }
                    .flatMap { abs($0.start - start) <= 1_500 ? $0 : nil }
            }?.words.map { RemoteCarLyrics.Word(start: $0.start, text: $0.text) }
            lines.append(RemoteCarLyrics.Line(
                start: start,
                end: end,
                text: text,
                words: words,
                translation: translations.flatMap { $0.indices.contains(index) ? $0[index] : nil },
                romanized: romanized.indices.contains(index) ? romanized[index] : nil
            ))
        }
        return RemoteCarLyrics(synced: shown.synced, lines: lines)
    }

    func levels(songID: String) async -> [Float]? {
        if let levels = app.seekbarLevels.levels(for: songID) { return levels }
        await app.seekbarLevels.load(songID)
        return app.seekbarLevels.levels(for: songID)
    }

    // MARK: - Library

    /// A page of the library for the car's knob: a handful of ways in at the top, then
    /// artists, albums, playlists and their songs.
    func browse(path: String) async -> RemoteCarBrowse? {
        let parts = path.split(separator: "/").map(String.init)
        let client = app.client
        func albumItems(_ albums: [Album]) -> [RemoteCarBrowse.Item] {
            albums.map { .init(kind: "album", id: $0.id, title: $0.name, subtitle: $0.artist, cover: $0.coverArt) }
        }
        func songItems(_ songs: [Song]) -> [RemoteCarBrowse.Item] {
            songs.map { .init(kind: "song", id: $0.id, title: $0.title, subtitle: $0.artist, cover: $0.coverArt) }
        }
        do {
            switch (parts.first ?? "", parts.count > 1 ? parts[1] : nil) {
            case ("", nil):
                return RemoteCarBrowse(title: "Library", items: [
                    .init(kind: "folder", id: "recent", title: "Recently Played"),
                    .init(kind: "folder", id: "playlists", title: "Playlists"),
                    .init(kind: "folder", id: "artists", title: "Artists"),
                    .init(kind: "folder", id: "albums", title: "Recently Added"),
                    .init(kind: "folder", id: "favourites", title: "Favourites"),
                ])
            case ("recent", nil):
                return RemoteCarBrowse(title: "Recently Played", items: albumItems(try await client.albums(type: .recent, size: 80)))
            case ("albums", nil):
                return RemoteCarBrowse(title: "Recently Added", items: albumItems(try await client.albums(type: .newest, size: 80)))
            case ("favourites", nil):
                let starred = try await client.starred()
                return RemoteCarBrowse(title: "Favourites", items: albumItems(starred.albums) + songItems(starred.songs))
            case ("artists", nil):
                let artists = try await client.artists().flatMap(\.artists)
                return RemoteCarBrowse(title: "Artists", items: artists.map {
                    .init(kind: "artist", id: $0.id, title: $0.name, subtitle: $0.albumCount.map { $0 == 1 ? "1 album" : "\($0) albums" }, cover: $0.coverArt)
                })
            case ("playlists", nil):
                return RemoteCarBrowse(title: "Playlists", items: try await client.playlists().map {
                    .init(kind: "playlist", id: $0.id, title: $0.name, subtitle: $0.songCount.map { "\($0) songs" }, cover: $0.coverArt)
                })
            case ("artist", let id?):
                let artist = try await client.artistDetail(id: id)
                return RemoteCarBrowse(title: artist.name, items: artist.albums.map {
                    .init(kind: "album", id: $0.id, title: $0.name, subtitle: $0.year.map(String.init), cover: $0.coverArt)
                })
            case ("album", let id?):
                let album = try await client.albumDetail(id: id)
                return RemoteCarBrowse(title: album.name, items: songItems(album.songs))
            case ("playlist", let id?):
                let playlist = try await client.playlistDetail(id: id)
                return RemoteCarBrowse(title: playlist.name, items: songItems(playlist.songs))
            default:
                return nil
            }
        } catch {
            return nil
        }
    }

    /// Plays what a browse page named: an album or playlist from `index`, an artist's songs.
    func playItem(kind: String, id: String, index: Int, shuffled: Bool) async -> Bool {
        let client = app.client
        do {
            let songs: [Song]
            let source: String
            switch kind {
            case "album":
                let album = try await client.albumDetail(id: id)
                (songs, source) = (album.songs, album.name)
            case "playlist":
                let playlist = try await client.playlistDetail(id: id)
                (songs, source) = (playlist.songs, playlist.name)
            case "artist":
                songs = try await client.artistSongs(id: id)
                source = songs.first?.artist ?? "Artist"
            case "song":
                let song = try await client.song(id: id)
                (songs, source) = ([song], song.title)
            default:
                return false
            }
            guard !songs.isEmpty else { return false }
            app.player.play(songs: songs, startingAt: min(max(0, index), songs.count - 1), source: source, shuffled: shuffled)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Timing and the spectrum

    var outputLatency: Double { AVAudioSession.sharedInstance().outputLatency }

    func spectrum() -> (mediaTime: Double, bands: [UInt8])? {
        analyser.frame(from: app.spectrumBuffer)
    }
}

/// 64 log-spaced bands from the newest 512 samples of the tap's ring, the way the phone's
/// visualizer reads it (mean out, Hann window, |X|/N), tagged with the song position at
/// the middle of the window.
///
/// Not isolated to the main actor, for `VisualizerFFT`'s reason: a `@MainActor` class
/// cannot free its FFT setup in `deinit` under strict concurrency. Only the provider, on
/// the main actor, calls it.
private final class CarSpectrumAnalyser: @unchecked Sendable {
    static let bands = 64
    private static let size = 512
    private let setup = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2))
    private var ring = [Float](repeating: 0, count: AudioSampleBuffer.capacity)
    private var window = [Float](repeating: 0, count: size)
    private var windowed = [Float](repeating: 0, count: size)
    private var real = [Float](repeating: 0, count: size / 2)
    private var imaginary = [Float](repeating: 0, count: size / 2)
    private var magnitudes = [Float](repeating: 0, count: size / 2)

    init() {
        vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_DENORM))
    }

    deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
    }

    func frame(from buffer: AudioSampleBuffer) -> (mediaTime: Double, bands: [UInt8])? {
        guard let setup, buffer.isReceiving else { return nil }
        let newest = buffer.newestMediaTime
        guard newest >= 0 else { return nil }
        buffer.snapshot(into: &ring)
        let size = Self.size
        ring.withUnsafeBufferPointer { samples in
            guard let base = samples.baseAddress else { return }
            let latest = base + (samples.count - size)
            var mean: Float = 0
            vDSP_meanv(latest, 1, &mean, vDSP_Length(size))
            var negated = -mean
            vDSP_vsadd(latest, 1, &negated, &windowed, 1, vDSP_Length(size))
        }
        windowed.withUnsafeMutableBufferPointer { w in
            window.withUnsafeBufferPointer { hann in
                vDSP_vmul(w.baseAddress!, 1, hann.baseAddress!, 1, w.baseAddress!, 1, vDSP_Length(size))
            }
        }
        real.withUnsafeMutableBufferPointer { re in
            imaginary.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, 9, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(size / 2))
            }
        }
        var scale = 1 / Float(size)
        magnitudes.withUnsafeMutableBufferPointer { m in
            vDSP_vsmul(m.baseAddress!, 1, &scale, m.baseAddress!, 1, vDSP_Length(size / 2))
        }
        magnitudes[0] = 0

        // 64 bands, logarithmic from ~40 Hz to the top, each the loudest bin it covers,
        // mapped from -70...-10 dB onto 0...255.
        let rate = buffer.sampleRate
        let binHz = rate / Double(size)
        var bands = [UInt8](repeating: 0, count: Self.bands)
        let low = 40.0, high = min(16_000.0, rate / 2)
        for band in 0..<Self.bands {
            let f0 = low * pow(high / low, Double(band) / Double(Self.bands))
            let f1 = low * pow(high / low, Double(band + 1) / Double(Self.bands))
            let k0 = max(1, Int(f0 / binHz)), k1 = max(k0, min(size / 2 - 1, Int(f1 / binHz)))
            var peak: Float = 0
            for k in k0...k1 { peak = max(peak, magnitudes[k]) }
            let db = 20 * log10(Double(peak) + 1e-9)
            bands[band] = UInt8(min(max((db + 70) / 60, 0), 1) * 255)
        }
        return (newest - Double(size / 2) / rate, bands)
    }
}
