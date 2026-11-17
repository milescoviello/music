import SwiftUI

/// Home's two grids of glass tiles, as the Linux app has them: Jump Back In at the top,
/// what was played lately, and the stations, each a small tile rather than a card.

/// The Linux app's glass: a light fill and a hairline edge over the cover's colours.
struct GlassTile: ViewModifier {
    var cornerRadius: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.07), lineWidth: 1)
            }
    }
}

extension View {
    func glassTile(cornerRadius: CGFloat = 10) -> some View {
        modifier(GlassTile(cornerRadius: cornerRadius))
    }
}

/// Up to eight of the recent plays, two to a row: a tap opens it.
struct JumpBackIn: View {
    @Environment(RecentPlaysStore.self) private var store
    @Environment(StationService.self) private var stations

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        let shown = Array(store.recent.origins.prefix(8))
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.headerToContent) {
                ShelfHeader(title: "Jump Back In")
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(shown) { origin in
                        item(origin)
                    }
                }
                .padding(.horizontal, Metrics.gutter)
            }
        }
    }

    @ViewBuilder
    private func item(_ origin: PlayOrigin) -> some View {
        switch origin {
        case let .album(id, name, artist, coverArt):
            NavigationLink(value: Destination.album(AlbumRef(id: id, name: name, artist: artist, coverArt: coverArt))) {
                tile(origin)
            }
            .buttonStyle(.plain)
        case let .playlist(id, name, coverArt):
            NavigationLink(value: Destination.playlist(PlaylistRef(id: id, name: name, coverArt: coverArt))) {
                tile(origin)
            }
            .buttonStyle(.plain)
        case let .artist(id, name, coverArt):
            NavigationLink(value: Destination.artist(ArtistRef(id: id, name: name, coverArt: coverArt))) {
                tile(origin)
            }
            .buttonStyle(.plain)
        case let .station(station, _):
            Button { stations.play(station) } label: { tile(origin) }
                .buttonStyle(.plain)
        }
    }

    /// A playlist's own chosen image wins over its cover, as everywhere else.
    private func playlistID(_ origin: PlayOrigin) -> String? {
        if case let .playlist(id, _, _) = origin { return id }
        return nil
    }

    private func tile(_ origin: PlayOrigin) -> some View {
        HStack(spacing: 10) {
            ArtworkImage(id: origin.coverArt, size: .thumb, cornerRadius: 0, playlistID: playlistID(origin), fallbackText: origin.title)
                .frame(width: 52, height: 52)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(origin.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(origin.subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .glassTile()
    }
}

/// Home's Stations: the four library stations and the mix builders, as glass tiles, two
/// to a row, each with its symbol in a square of the accent.
struct StationTiles: View {
    @Environment(StationService.self) private var stations

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.headerToContent) {
            ShelfHeader(title: "Stations", seeAll: .stations)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(StationsShelf.core) { station in
                    Button {
                        stations.play(station)
                    } label: {
                        tile(title: station.title, subtitle: station.subtitle, symbol: station.symbol,
                             isLoading: stations.starting == station)
                    }
                    .buttonStyle(.plain)
                }
                NavigationLink(value: Destination.mixBuilder(.artists)) {
                    tile(title: "Artist Mix Builder", subtitle: "Pick a few artists",
                         symbol: Station.artistMix(ids: [], names: []).symbol, isLoading: false)
                }
                .buttonStyle(.plain)
                NavigationLink(value: Destination.mixBuilder(.albums)) {
                    tile(title: "Album Mix Builder", subtitle: "Pick a few albums",
                         symbol: Station.albumMix(ids: [], names: []).symbol, isLoading: false)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Metrics.gutter)
        }
    }

    private func tile(title: String, subtitle: String, symbol: String, isLoading: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.appTint.opacity(0.28))
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.appTint)
                }
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .glassTile()
    }
}
