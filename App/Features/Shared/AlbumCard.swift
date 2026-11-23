import SwiftUI

struct AlbumCard: View {
    let album: Album
    /// What goes under the name. On an artist's own page the artist said nothing the page
    /// does not; the year does.
    var detail: Detail = .artist

    enum Detail { case artist, year }

    var body: some View {
        let name = AlbumEdition.split(album.name)
        VStack(alignment: .leading, spacing: 8) {
            ArtworkImage(id: album.coverArt, size: .card, fallbackText: album.name)
                .aspectRatio(1, contentMode: .fit)

            VStack(alignment: .leading, spacing: 4) {
                Text(name.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                // The tag on the detail line rather than one of its own: a shelf is as tall as
                // its first card, and a card a line taller had its cover shrunk, or its last
                // line cut off.
                if name.edition != nil || line != nil {
                    HStack(spacing: 6) {
                        if let edition = name.edition {
                            Text(edition)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.appTint)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .background(Color.appTint.opacity(0.16), in: Capsule())
                                .layoutPriority(1)
                        }
                        if let line {
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var line: String? {
        switch detail {
        case .artist: album.artist
        case .year: album.year.map(String.init)
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
