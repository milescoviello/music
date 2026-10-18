import SwiftUI

struct GenreListView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope

    @State private var genres: [Genre] = []

    var body: some View {
        List {
            ForEach(genres) { genre in
                NavigationLink(value: Destination.genre(genre.value)) {
                    HStack {
                        Text(genre.value)
                        Spacer(minLength: 8)
                        if let count = genre.albumCount {
                            Text("\(count)")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(minHeight: Metrics.rowCategory)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        startGenreRadio(genre.value)
                    } label: {
                        Label("Radio", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .tint(.appTint)
                }
                .contextMenu {
                    Button("Genre Radio", systemImage: "dot.radiowaves.left.and.right") {
                        startGenreRadio(genre.value)
                    }
                }
            }
        }
        .listStyle(.plain)
        .playerClearance()
        .navigationTitle("Genres")
        .refreshable { await load() }
        .task(id: scope.generation) { await load() }
    }

    /// A random draw within the genre, which the server supports directly -- so this
    /// is genuinely "genre radio" rather than a shuffle of a fixed page of results.
    private func startGenreRadio(_ genre: String) {
        Task {
            let mix = await appState.radio.genreMix(genre, scope: scope.scope)
            appState.startRadio(named: "\(genre) Radio", songs: mix, station: .genre(genre))
        }
    }

    private func load() async {
        // Sorted by album count: 366 genres alphabetically is a wall of noise,
        // while the largest genres are what you actually browse.
        let client = appState.client
        let currentScope = scope.scope
        appState.beginLoadPass()
        let fetched: [Genre] = await appState.cached(
            CacheKey.genres(currentScope.cacheKey)
        ) {
            try await client.genres(scope: currentScope)
        } ?? []
        genres = fetched
            .sorted { ($0.albumCount ?? 0) > ($1.albumCount ?? 0) }
    }
}

/// Albums *or* songs, because a genre is one of the few places where wanting the tracks
/// themselves is as likely as wanting the records. `songsByGenre` already existed and was
/// only ever reached as a fallback inside `RadioBuilder.genreMix`.
struct GenreDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope

    let genre: String

    private enum Facet: String, CaseIterable, Identifiable {
        case albums, songs
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    @State private var facet: Facet = .albums

    var body: some View {
        Group {
            switch facet {
            case .albums: AlbumListView(genre: genre)
            case .songs: GenreSongsView(genre: genre)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Show", selection: $facet) {
                ForEach(Facet.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        let mix = await appState.radio.genreMix(genre, scope: scope.scope)
                        appState.startRadio(named: "\(genre) Radio", songs: mix, station: .genre(genre))
                    }
                } label: {
                    Image(systemName: "dot.radiowaves.left.and.right")
                }
                .accessibilityLabel("Genre radio")
            }
        }
    }
}

/// Paged songs in one genre, using the same sentinel idiom as `AlbumListView`.
private struct GenreSongsView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope

    let genre: String

    @State private var songs: [Song] = []
    @State private var isLoadingPage = false
    @State private var canLoadMore = true

    private let pageSize = 100

    var body: some View {
        List {
            ForEach(Array(songs.enumerated()), id: \.offset) { index, _ in
                PlayableSongRow(songs: songs, index: index, source: genre)
            }

            if canLoadMore, !songs.isEmpty {
                // A sentinel rather than scroll-offset maths: `.task` on a lazily created
                // row fires exactly when it is needed and cancels correctly.
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .task { await loadMore() }
            }
        }
        .listStyle(.plain)
        .playerClearance()
        .overlay {
            if songs.isEmpty, isLoadingPage { ProgressView() }
        }
        .overlay {
            if songs.isEmpty, !isLoadingPage {
                ContentUnavailableView(
                    "No Songs",
                    systemImage: "music.note",
                    description: Text("Nothing in your library is tagged \(genre).")
                )
            }
        }
        .task(id: scope.generation) {
            songs = []
            canLoadMore = true
            await loadMore()
        }
    }

    private func loadMore() async {
        guard !isLoadingPage, canLoadMore else { return }
        isLoadingPage = true

        let page = (try? await appState.client.songsByGenre(
            genre,
            count: pageSize,
            offset: songs.count,
            scope: scope.scope
        )) ?? []

        songs.append(contentsOf: page)
        canLoadMore = page.count == pageSize
        isLoadingPage = false
    }
}
