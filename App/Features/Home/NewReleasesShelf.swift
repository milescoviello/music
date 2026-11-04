import SwiftUI

/// New releases by artists you play that the library does not have yet. Tap one to have
/// Hermes get it.
struct NewReleasesShelf: View {
    @Environment(AppState.self) private var appState
    @State private var asking: SonicClient.RadarItem?

    var body: some View {
        let radar = appState.radar
        Group {
            if !radar.items.isEmpty {
                VStack(alignment: .leading, spacing: Metrics.headerToContent) {
                    ShelfHeader(title: "New Releases")
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: Metrics.itemSpacing) {
                            ForEach(radar.items) { item in
                                Button { asking = item } label: { card(item, requested: radar.requested.contains(item.id)) }
                                    .buttonStyle(.plain)
                                    .frame(width: Metrics.cardWidth)
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
        .task { await radar.load() }
        .confirmationDialog(
            asking.map { "“\($0.title)” by \($0.artist)" } ?? "",
            isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
            titleVisibility: .visible,
            presenting: asking
        ) { item in
            if radar.canRequest {
                Button(radar.requested.contains(item.id) ? "Request Again" : "Request It") {
                    Task { _ = await radar.request(item) }
                }
            }
        } message: { item in
            Text(radar.canRequest
                ? "\(ReleaseRadar.detail(item)). Hermes will look for it and add it to the library."
                : "\(ReleaseRadar.detail(item)). Set up requests in Settings to ask Hermes for it.")
        }
    }

    private func card(_ item: SonicClient.RadarItem, requested: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            RadarCover(item: item)
            .frame(width: Metrics.cardWidth, height: Metrics.cardWidth)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if requested {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.appTint)
                        .font(.title3)
                        .padding(6)
                }
            }
            Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
            Text(item.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(requested ? "Requested" : ReleaseRadar.detail(item))
                .font(.caption2)
                .foregroundStyle(item.upcoming ? Color.appTint : .secondary)
                .lineLimit(1)
        }
    }
}

/// A release's cover, through the sonic service rather than straight from the archive,
/// whose redirect to archive.org some networks refuse.
private struct RadarCover: View {
    @Environment(AppState.self) private var appState
    let item: SonicClient.RadarItem
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.15)
                Image(systemName: "sparkles").font(.title2).foregroundStyle(.secondary)
            }
        }
        .task(id: item.id) {
            let client = SonicClient(configuration: appState.sonic.configuration)
            if let data = await client.radarCover(item) { image = UIImage(data: data) }
        }
    }
}
