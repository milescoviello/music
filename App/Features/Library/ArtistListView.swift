import SwiftUI

/// `getArtists` returns the whole indexed list in one call. At 400 artists that is
/// cheap to hold in memory and needs no pagination or index rail.
struct ArtistListView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope

    @State private var indexes: [ArtistIndex] = []
    @State private var isLoading = false

    var body: some View {
        ScrollViewReader { proxy in
            list
                .overlay(alignment: .trailing) {
                    if flatArtists.count > 40 {
                        let sections = firstArtistByLetter
                        AlphabetRail(available: Set(sections.keys)) { letter in
                            guard let target = sections[letter] else { return }
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(target.id, anchor: .top)
                            }
                        }
                        .padding(.trailing, 2)
                    }
                }
        }
    }

    private var flatArtists: [Artist] {
        indexes.flatMap(\.artists)
    }

    /// The rail's letters from the server's own sections, each to the section's first
    /// artist. Worked out here from each name instead, they disagreed with the sections
    /// they jumped into: Navidrome files by its ignored articles -- The, El, La, Los, Las,
    /// Le, Les, Os, As, O and A -- where the rail knew only The, A and An, so "La Roux"
    /// sat under R while the rail called it L. Its "X-Z" section answers all three.
    private var firstArtistByLetter: [String: Artist] {
        var map: [String: Artist] = [:]
        for index in indexes {
            guard let first = index.artists.first else { continue }
            for letter in Self.letters(inSection: index.name) where map[letter] == nil {
                map[letter] = first
            }
        }
        return map
    }

    private static func letters(inSection name: String) -> [String] {
        let ends = name.uppercased().split(separator: "-").compactMap(\.unicodeScalars.first)
        if ends.count == 2, ends[0].value < ends[1].value {
            return (ends[0].value...ends[1].value).compactMap { Unicode.Scalar($0).map(String.init) }
        }
        return [name.uppercased()]
    }

    private var list: some View {
        List {
            ForEach(indexes) { index in
                Section(index.name) {
                    ForEach(index.artists) { artist in
                        NavigationLink(value: Destination.artist(ArtistRef(artist))) {
                            HStack(spacing: Metrics.itemSpacing) {
                                ArtistArtwork(
                                    id: artist.coverArt,
                                    diameter: 40,
                                    initials: artist.name.monogram
                                )

                                Text(artist.name)
                                    .lineLimit(1)

                                Spacer(minLength: 8)

                                if let count = artist.albumCount {
                                    Text("\(count)")
                                        .font(.footnote.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .id(artist.id)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            FavoriteSwipeButton(
                                id: artist.id, kind: .artist, serverValue: artist.starred != nil
                            )
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .playerClearance()
        .navigationTitle("Artists")
        .overlay {
            if isLoading, indexes.isEmpty { ProgressView() }
        }
        .refreshable { await load() }
        .task(id: scope.generation) { await load() }
    }

    private func load() async {
        isLoading = true
        let client = appState.client
        let currentScope = scope.scope
        appState.beginLoadPass()
        indexes = await appState.cached(CacheKey.artistIndex(currentScope.cacheKey)) {
            try await client.artists(scope: currentScope)
        } ?? []
        isLoading = false
    }
}
