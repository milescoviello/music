import SwiftUI

/// Concerts coming up near home by the artists played most (`NearbyShows`). A card opens
/// the ticket page.
struct ShowsShelf: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL

    var body: some View {
        let shows = appState.shows
        Group {
            if !shows.items.isEmpty {
                VStack(alignment: .leading, spacing: Metrics.headerToContent) {
                    ShelfHeader(title: "Shows Near You")
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: Metrics.itemSpacing) {
                            ForEach(shows.items) { show in
                                Button {
                                    if let url = URL(string: show.url) { openURL(url) }
                                } label: { card(show) }
                                    .buttonStyle(.plain)
                                    .frame(width: Metrics.cardWidth)
                                    .accessibilityLabel("\(show.artist), \(NearbyShows.when(show)), \(NearbyShows.place(show))")
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .contentMargins(.horizontal, Metrics.gutter, for: .scrollContent)
                    .scrollIndicators(.hidden)
                }
            }
        }
        .task { await shows.load() }
    }

    private func card(_ show: SonicClient.Show) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            AsyncImage(url: show.image.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "ticket").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(width: Metrics.cardWidth, height: Metrics.cardWidth)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
            Text(show.artist).font(.subheadline.weight(.medium)).lineLimit(1)
            Text(NearbyShows.when(show)).font(.caption).foregroundStyle(Color.appTint).lineLimit(1)
            Text(NearbyShows.place(show)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
