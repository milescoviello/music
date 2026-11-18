import UIKit
import WidgetKit

/// Keeps the widgets' snapshot (`WidgetSnapshot`) up to date: the song, whether it plays,
/// its cover, and today's Made for You. Written only when something shown changes, and each
/// write asks the widgets that show it to reload -- they have a daily budget of reloads.
@MainActor
final class WidgetPublisher {
    static let shared = WidgetPublisher()

    private var snapshot = WidgetSnapshot.load() ?? WidgetSnapshot()
    private var coverSongID: String?

    /// From the lock screen's own updates (`NowPlayingCenter`): the same moments -- a new
    /// song, play, pause, a seek. The position goes with them, so the widget's progress
    /// bar runs by itself between.
    func nowPlaying(_ song: Song?, isPlaying: Bool, elapsed: Double = 0, duration: Double = 0, speed: Float = 1) {
        guard AppGroup.container != nil else { return }
        var next = snapshot
        next.title = song?.title
        next.artist = song?.artist
        next.album = song?.album
        next.isPlaying = song != nil && isPlaying
        next.elapsed = song == nil ? nil : elapsed
        next.duration = song == nil ? nil : duration
        next.rate = next.isPlaying ? Double(speed) : 0
        next.anchor = .now
        if song == nil {
            next.quality = nil
            next.rating = nil
            next.isFavourite = nil
            next.upNext = nil
        } else if let song, song.title != snapshot.title || song.artist != snapshot.artist {
            next.quality = Self.quality(of: song)
        }
        // Where the bar already thinks the song is, to tell a seek from the clock running.
        let predicted = (snapshot.elapsed ?? 0) + Date.now.timeIntervalSince(snapshot.anchor ?? .now) * (snapshot.rate ?? 0)
        let moved = abs(predicted - elapsed) > 2 || next.duration != snapshot.duration
        guard next.title != snapshot.title || next.artist != snapshot.artist || next.album != snapshot.album
            || next.isPlaying != snapshot.isPlaying || moved
        else { return }
        if song?.id != coverSongID {
            // The last song's cover would show under this one's name until its own arrives.
            WidgetSnapshot.setImage(nil, WidgetSnapshot.coverName)
            coverSongID = nil
        }
        store(next, reloading: "NowPlaying")
    }

    func artwork(_ image: UIImage, songID: String?) {
        guard AppGroup.container != nil, let songID, songID != coverSongID else { return }
        coverSongID = songID
        WidgetSnapshot.setImage(Self.jpeg(image, side: 300), WidgetSnapshot.coverName)
        WidgetCenter.shared.reloadTimelines(ofKind: "NowPlaying")
    }

    func mixes(_ mixes: [DailyMixes.Mix], artwork: ArtworkStore) async {
        guard AppGroup.container != nil else { return }
        let shown = Array(mixes.prefix(6))
        let listed = shown.enumerated().map {
            WidgetSnapshot.Mix(number: $0.offset + 1, title: $0.element.title, subtitle: $0.element.subtitle)
        }
        guard listed != snapshot.mixes else { return }
        for (index, mix) in shown.enumerated() {
            let image = await artwork.image(for: mix.covers.first, size: .thumb)
            WidgetSnapshot.setImage(image.flatMap { Self.jpeg($0, side: 200) }, WidgetSnapshot.mixCoverName(index + 1))
        }
        var next = snapshot
        next.mixes = listed
        store(next, reloading: "MadeForYou")
    }

    /// The rest of the Linux player's lines for the song playing: its stars, its heart and
    /// what comes next. Written only when one of them changes.
    func details(rating: Int, isFavourite: Bool, upNext: [Song]) {
        guard AppGroup.container != nil, snapshot.title != nil else { return }
        var next = snapshot
        next.rating = rating
        next.isFavourite = isFavourite
        next.upNext = upNext.prefix(4).map { WidgetSnapshot.Line(title: $0.title, artist: $0.artist) }
        guard next.rating != snapshot.rating || next.isFavourite != snapshot.isFavourite || next.upNext != snapshot.upNext
        else { return }
        store(next, reloading: "NowPlaying")
    }

    /// The playing song's cover colours and accent (`CoverTint`), so the widgets have the
    /// app's backdrop behind them.
    func colours(pools: [VisualizerPalette.RGB], accent: (r: Double, g: Double, b: Double)?) {
        guard AppGroup.container != nil else { return }
        var next = snapshot
        next.pools = pools.map { [$0.r, $0.g, $0.b] }
        next.accent = accent.map { [$0.r, $0.g, $0.b] }
        guard next.pools != snapshot.pools || next.accent != snapshot.accent else { return }
        store(next, reloading: "NowPlaying")
        WidgetCenter.shared.reloadTimelines(ofKind: "MadeForYou")
    }

    /// "FLAC · 24/96", "MP3 · 320 kbps": the file's own format, as the player's codec line
    /// starts.
    static func quality(of song: Song) -> String? {
        var parts: [String] = []
        if let suffix = song.suffix { parts.append(suffix.uppercased()) }
        let lossless = ["flac", "wav", "aiff", "aif", "alac"].contains(song.suffix?.lowercased() ?? "")
        if lossless, let depth = song.bitDepth, let rate = song.samplingRate, rate > 0 {
            let khz = Double(rate) / 1000
            parts.append("\(depth)/\(khz == khz.rounded() ? String(Int(khz)) : String(format: "%.1f", khz))")
        } else if !lossless, let rate = song.bitRate, rate > 0 {
            parts.append("\(rate) kbps")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The pinned playlists, which Now Playing shows when nothing is playing: up to four,
    /// in his order, each with its cover -- his own chosen image where there is one.
    func pinned(_ playlists: [Playlist], artwork: ArtworkStore, custom: PlaylistArtwork) async {
        guard AppGroup.container != nil else { return }
        let shown = Array(playlists.prefix(4))
        let listed = shown.map { WidgetSnapshot.Pinned(id: $0.id, name: $0.name) }
        guard listed != snapshot.pinned else { return }
        for (index, playlist) in shown.enumerated() {
            var image = custom.image(for: playlist.id)
            if image == nil { image = await artwork.image(for: playlist.coverArt, size: .thumb) }
            WidgetSnapshot.setImage(image.flatMap { Self.jpeg($0, side: 200) }, WidgetSnapshot.pinnedCoverName(index + 1))
        }
        var next = snapshot
        next.pinned = listed
        store(next, reloading: "NowPlaying")
    }

    private func store(_ next: WidgetSnapshot, reloading kind: String) {
        snapshot = next
        snapshot.updated = .now
        snapshot.save()
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }

    /// A square, filled: what a widget's cover slot is.
    static func jpeg(_ image: UIImage, side: CGFloat) -> Data? {
        let size = CGSize(width: side, height: side)
        let scale = max(side / max(image.size.width, 1), side / max(image.size.height, 1))
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.8) { _ in
            image.draw(in: CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2,
                                  width: drawn.width, height: drawn.height))
        }
    }
}
