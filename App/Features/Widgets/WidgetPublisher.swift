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

    /// From the lock screen's own updates (`NowPlayingCenter`): the same moments.
    func nowPlaying(_ song: Song?, isPlaying: Bool) {
        guard AppGroup.container != nil else { return }
        var next = snapshot
        next.title = song?.title
        next.artist = song?.artist
        next.album = song?.album
        next.isPlaying = song != nil && isPlaying
        guard next.title != snapshot.title || next.artist != snapshot.artist || next.album != snapshot.album
            || next.isPlaying != snapshot.isPlaying
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
