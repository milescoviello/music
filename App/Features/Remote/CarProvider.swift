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
        guard let sets, let shown = StructuredLyrics.shown(from: sets), !shown.lines.isEmpty else { return nil }
        let offset = shown.synced ? (shown.offset ?? 0) : 0
        let texts: [String] = shown.lines.map { (line: LyricLine) -> String in line.value }
        var wordLines: [SonicClient.WordLine] = []
        if shown.synced, let kept = await LyricsStore.shared.words(songID: songID) { wordLines = kept }
        let translations: [String?] = await LyricTranslationStore.shared.translations(songID: songID, lines: texts) ?? []
        let tag = shown.lang
        // Off the main actor, as the lyrics screen does it: tokenizing Japanese takes a while.
        let romanized: [String?] = await Task.detached(priority: .userInitiated) {
            Romanizer.romanize(texts, language: LyricsLanguage.detect(texts, tag: tag))
        }.value

        var starts: [Int?] = []
        for line in shown.lines {
            if let start = line.start { starts.append(max(0, start - offset)) } else { starts.append(nil) }
        }
        var lines: [RemoteCarLyrics.Line] = []
        for index in texts.indices {
            let start = starts[index]
            var end: Int?
            for later in starts[(index + 1)...] where later != nil {
                end = later
                break
            }
            let translation: String? = index < translations.count ? translations[index] : nil
            let romanization: String? = index < romanized.count ? romanized[index] : nil
            lines.append(RemoteCarLyrics.Line(
                start: start,
                end: end,
                text: texts[index],
                words: Self.words(near: start, in: wordLines),
                translation: translation,
                romanized: romanization
            ))
        }
        return RemoteCarLyrics(synced: shown.synced, lines: lines)
    }

    /// Word timing comes from another source than the lines (LRCLIB, through the sonic
    /// service), so a line's words are the timed line starting nearest it, within 1.5 s.
    private static func words(near start: Int?, in wordLines: [SonicClient.WordLine]) -> [RemoteCarLyrics.Word]? {
        guard let start else { return nil }
        var best: SonicClient.WordLine?
        var bestDistance = Int.max
        for candidate in wordLines {
            let distance = abs(candidate.start - start)
            if distance < bestDistance {
                best = candidate
                bestDistance = distance
            }
        }
        guard let best, bestDistance <= 1_500 else { return nil }
        return best.words.map { (word: SonicClient.WordLine.Word) -> RemoteCarLyrics.Word in
            RemoteCarLyrics.Word(start: word.start, text: word.text)
        }
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
        let first = parts.first ?? ""
        let id: String? = parts.count > 1 ? parts[1] : nil
        let client = app.client
        do {
            switch (first, id) {
            case ("", nil):
                return RemoteCarBrowse(title: "Library", items: [
                    RemoteCarBrowse.Item(kind: "folder", id: "recent", title: "Recently Played"),
                    RemoteCarBrowse.Item(kind: "folder", id: "playlists", title: "Playlists"),
                    RemoteCarBrowse.Item(kind: "folder", id: "artists", title: "Artists"),
                    RemoteCarBrowse.Item(kind: "folder", id: "albums", title: "Recently Added"),
                    RemoteCarBrowse.Item(kind: "folder", id: "favourites", title: "Favourites"),
                ])
            case ("recent", nil):
                let albums = try await client.albums(type: .recent, size: 80)
                return RemoteCarBrowse(title: "Recently Played", items: Self.items(albums))
            case ("albums", nil):
                let albums = try await client.albums(type: .newest, size: 80)
                return RemoteCarBrowse(title: "Recently Added", items: Self.items(albums))
            case ("favourites", nil):
                let starred = try await client.starred()
                return RemoteCarBrowse(title: "Favourites", items: Self.items(starred.albums) + Self.items(starred.songs))
            case ("artists", nil):
                let indexes = try await client.artists()
                var items: [RemoteCarBrowse.Item] = []
                for index in indexes {
                    for artist in index.artists {
                        items.append(RemoteCarBrowse.Item(
                            kind: "artist", id: artist.id, title: artist.name,
                            subtitle: Self.count(artist.albumCount, "album"), cover: artist.coverArt
                        ))
                    }
                }
                return RemoteCarBrowse(title: "Artists", items: items)
            case ("playlists", nil):
                let playlists = try await client.playlists()
                var items: [RemoteCarBrowse.Item] = []
                for playlist in playlists {
                    items.append(RemoteCarBrowse.Item(
                        kind: "playlist", id: playlist.id, title: playlist.name,
                        subtitle: Self.count(playlist.songCount, "song"), cover: playlist.coverArt
                    ))
                }
                return RemoteCarBrowse(title: "Playlists", items: items)
            case ("artist", let id?):
                let artist = try await client.artistDetail(id: id)
                var items: [RemoteCarBrowse.Item] = []
                for album in artist.albums {
                    let year: String? = album.year.map { (year: Int) -> String in String(year) }
                    items.append(RemoteCarBrowse.Item(kind: "album", id: album.id, title: album.name, subtitle: year, cover: album.coverArt))
                }
                return RemoteCarBrowse(title: artist.name, items: items)
            case ("album", let id?):
                let album = try await client.albumDetail(id: id)
                return RemoteCarBrowse(title: album.name, items: Self.items(album.songs))
            case ("playlist", let id?):
                let playlist = try await client.playlistDetail(id: id)
                return RemoteCarBrowse(title: playlist.name, items: Self.items(playlist.songs))
            default:
                return nil
            }
        } catch {
            return nil
        }
    }

    private static func items(_ albums: [Album]) -> [RemoteCarBrowse.Item] {
        var items: [RemoteCarBrowse.Item] = []
        for album in albums {
            items.append(RemoteCarBrowse.Item(kind: "album", id: album.id, title: album.name, subtitle: album.artist, cover: album.coverArt))
        }
        return items
    }

    private static func items(_ songs: [Song]) -> [RemoteCarBrowse.Item] {
        var items: [RemoteCarBrowse.Item] = []
        for song in songs {
            items.append(RemoteCarBrowse.Item(kind: "song", id: song.id, title: song.title, subtitle: song.artist, cover: song.coverArt))
        }
        return items
    }

    /// "1 album", "12 albums"; nil when the server didn't say.
    private static func count(_ value: Int?, _ noun: String) -> String? {
        guard let value else { return nil }
        return value == 1 ? "1 \(noun)" : "\(value) \(noun)s"
    }

    /// Plays what a browse page named: an album or playlist from `index`, an artist's songs.
    func playItem(kind: String, id: String, index: Int, shuffled: Bool) async -> Bool {
        let client = app.client
        var songs: [Song] = []
        var source = ""
        do {
            switch kind {
            case "album":
                let album = try await client.albumDetail(id: id)
                songs = album.songs
                source = album.name
            case "playlist":
                let playlist = try await client.playlistDetail(id: id)
                songs = playlist.songs
                source = playlist.name
            case "artist":
                songs = try await client.artistSongs(id: id)
                source = songs.first?.artist ?? "Artist"
            case "song":
                let song = try await client.song(id: id)
                songs = [song]
                source = song.title
            default:
                return false
            }
        } catch {
            return false
        }
        guard !songs.isEmpty else { return false }
        let start = min(max(0, index), songs.count - 1)
        app.player.play(songs: songs, startingAt: start, source: source, shuffled: shuffled)
        return true
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
    private var window = [Float](repeating: 0, count: CarSpectrumAnalyser.size)
    private var windowed = [Float](repeating: 0, count: CarSpectrumAnalyser.size)
    private var real = [Float](repeating: 0, count: CarSpectrumAnalyser.size / 2)
    private var imaginary = [Float](repeating: 0, count: CarSpectrumAnalyser.size / 2)
    private var magnitudes = [Float](repeating: 0, count: CarSpectrumAnalyser.size / 2)

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
