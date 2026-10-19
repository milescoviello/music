import SwiftUI

struct AlbumCard: View {
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkImage(id: album.coverArt, size: .card, fallbackText: album.name)
                .aspectRatio(1, contentMode: .fit)

            Text(album.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            if let artist = album.artist {
                Text(artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct PlaylistCard: View {
    let playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkImage(
                id: playlist.coverArt, size: .card,
                playlistID: playlist.id, fallbackText: playlist.name
            )
                .aspectRatio(1, contentMode: .fit)

            Text(playlist.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            if let count = playlist.songCount {
                Text("\(count) songs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Loads the covers of the next few albums of a grid into memory as a card comes into
/// view, so a fast scroll finds them there instead of drawing placeholders first.
private struct CoverPrefetch: ViewModifier {
    @Environment(ArtworkStore.self) private var artwork

    let albums: [Album]
    let index: Int

    func body(content: Content) -> some View {
        content.onAppear {
            guard index + 1 < albums.count else { return }
            // Two columns, so a dozen is the next six rows.
            artwork.prefetch(albums[(index + 1)..<min(index + 13, albums.count)].lazy.map(\.coverArt), size: .card)
        }
    }
}

extension View {
    func prefetchingCovers(of albums: [Album], after index: Int) -> some View {
        modifier(CoverPrefetch(albums: albums, index: index))
    }
}
