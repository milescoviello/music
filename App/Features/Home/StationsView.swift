import SwiftUI

/// Plexamp's Stations: radios that never end, by the library, by decade, by genre, and
/// the two Mix Builders.
struct StationsView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope
    @Environment(SonicService.self) private var sonic

    @State private var decades: [Int] = []
    @State private var genres: [Genre] = []

    var body: some View {
        List {
            Section("Stations") {
                ForEach(StationsShelf.core) { station in
                    StationRow(station: station)
                }
            }

            Section("Mix Builders") {
                NavigationLink(value: Destination.mixBuilder(.artists)) {
                    Label("Artist Mix Builder", systemImage: Station.artistMix(ids: [], names: []).symbol)
                }
                NavigationLink(value: Destination.mixBuilder(.albums)) {
                    Label("Album Mix Builder", systemImage: Station.albumMix(ids: [], names: []).symbol)
                }
            }

            // From the sonic analysis: what the music sounds like, not how it is tagged.
            if sonic.isAvailable {
                Section("Moods") {
                    ForEach(Station.moodTags, id: \.self) { tag in
                        StationRow(station: .mood(tag))
                    }
                }
            }

            if !decades.isEmpty {
                Section("Decades") {
                    ForEach(decades, id: \.self) { start in
                        StationRow(station: .decade(start))
                    }
                }
            }

            if !genres.isEmpty {
                Section("Genres") {
                    ForEach(genres) { genre in
                        StationRow(station: .genre(genre.value))
                    }
                }
            }
        }
        .navigationTitle("Stations")
        .playerClearance()
        .task(id: scope.generation) { await load() }
    }

    /// Only the decades the library has something in, newest first — probed with one
    /// tiny request each, all at once.
    private func load() async {
        let client = appState.client
        let current = scope.scope
        let thisYear = Calendar.current.component(.year, from: .now)
        let candidates = Array(stride(from: AutoplayRules.decadeStart(of: thisYear), through: 1920, by: -10))

        var found: Set<Int> = []
        await withTaskGroup(of: (Int, Bool).self) { group in
            for start in candidates {
                group.addTask {
                    let albums = (try? await client.albums(fromYear: start, toYear: start + 9, size: 1, scope: current)) ?? []
                    return (start, !albums.isEmpty)
                }
            }
            for await (start, present) in group where present {
                found.insert(start)
            }
        }
        decades = candidates.filter(found.contains)

        let all = (try? await client.genres(scope: current)) ?? []
        genres = Array(all.sorted { ($0.songCount ?? 0) > ($1.songCount ?? 0) }.prefix(16))
    }
}

/// One station, as a row: tap to play. The spinner shows while its first batch loads.
struct StationRow: View {
    @Environment(StationService.self) private var stations

    let station: Station

    var body: some View {
        Button {
            stations.play(station)
        } label: {
            HStack(spacing: Metrics.itemSpacing) {
                Image(systemName: station.symbol)
                    .font(.title3)
                    .foregroundStyle(Color.appTint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(station.title)
                    Text(station.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if stations.starting == station {
                    ProgressView()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Home's Stations shelf: the four library stations and the mix builders, as cards.
struct StationsShelf: View {
    @Environment(StationService.self) private var stations

    static let core: [Station] = [.library, .deepCuts, .timeTravel, .randomAlbum]

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.headerToContent) {
            ShelfHeader(title: "Stations", seeAll: .stations)

            ScrollView(.horizontal) {
                LazyHStack(spacing: Metrics.itemSpacing) {
                    ForEach(Self.core) { station in
                        Button {
                            stations.play(station)
                        } label: {
                            card(title: station.title, subtitle: station.subtitle, symbol: station.symbol,
                                 isLoading: stations.starting == station)
                        }
                        .buttonStyle(.plain)
                    }
                    NavigationLink(value: Destination.mixBuilder(.artists)) {
                        card(title: "Artist Mix Builder", subtitle: "Pick a few artists",
                             symbol: Station.artistMix(ids: [], names: []).symbol, isLoading: false)
                    }
                    .buttonStyle(.plain)
                    NavigationLink(value: Destination.mixBuilder(.albums)) {
                        card(title: "Album Mix Builder", subtitle: "Pick a few albums",
                             symbol: Station.albumMix(ids: [], names: []).symbol, isLoading: false)
                    }
                    .buttonStyle(.plain)
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, Metrics.gutter, for: .scrollContent)
            .scrollIndicators(.hidden)
        }
    }

    private func card(title: String, subtitle: String, symbol: String, isLoading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.appTint.opacity(0.55), Color.appTint.opacity(0.15)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                if isLoading {
                    ProgressView()
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: Metrics.cardWidth * 0.75, height: Metrics.cardWidth * 0.75)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
        }
        .frame(width: Metrics.cardWidth * 0.75, alignment: .leading)
    }
}
