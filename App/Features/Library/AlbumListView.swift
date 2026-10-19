import SwiftUI

struct AlbumListView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope
    @Environment(DownloadCenter.self) private var downloads

    @AppStorage("library.downloadedOnly") private var downloadedOnly = false

    var initialSort: AlbumSort = .newest
    /// Set when this list is a genre drill-down.
    var genre: String?
    /// Set when this list is a decade drill-down; the first year, so 1990 means 1990-1999.
    var decade: Int?

    @State private var albums: [Album] = []
    @State private var sort: AlbumSort = .newest
    @State private var error: String?
    @State private var isLoadingPage = false
    @State private var canLoadMore = true
    @State private var didApplyInitialSort = false

    /// Fixed two columns: the app is portrait-only, so `.adaptive` buys nothing and
    /// costs a stable grid.
    private let columns = [
        GridItem(.flexible(), spacing: Metrics.itemSpacing),
        GridItem(.flexible(), spacing: Metrics.itemSpacing),
    ]

    private var pageSize: Int { 100 }

    var body: some View {
        ScrollView {
            if let error, albums.isEmpty {
                ContentUnavailableView {
                    Label("Can't load albums", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await reload() } }
                }
                .padding(.top, 60)
            } else {
                let shown = displayed
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, album in
                        NavigationLink(value: Destination.album(AlbumRef(album))) {
                            AlbumCard(album: album)
                        }
                        .buttonStyle(.plain)
                        .albumMenu(album)
                        .prefetchingCovers(of: shown, after: index)
                    }
                }
                .padding(.horizontal, Metrics.gutter)

                // A sentinel rather than scroll-offset maths: `.task` on a lazily
                // created view is cancellation-correct and fires exactly when the
                // user reaches the end.
                // Never paged while filtering to downloads: the list is the catalog, and
                // it is already whole.
                if canLoadMore, !albums.isEmpty, !isFilteringToDownloads {
                    ProgressView()
                        .padding(.vertical, 24)
                        .task { await loadMore() }
                }
            }
        }
        .navigationTitle(genre ?? decade.map { "\($0)s" } ?? "Albums")
        .playerClearance()
        .toolbar {
            if genre == nil, decade == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(AlbumSort.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        Divider()
                        Toggle("Downloaded Only", isOn: $downloadedOnly)
                            // Offline it is not a choice: the server cannot answer, so
                            // this turns "empty lists" into "your library, smaller".
                            .disabled(!appState.reachability.isOnline)
                    } label: {
                        // Show the current sort as text: a bare glyph hides state.
                        Label(sort.title, systemImage: "arrow.up.arrow.down")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { LibraryScopeMenu() }
            }
        }
        .overlay {
            if isLoadingPage, albums.isEmpty, !isFilteringToDownloads { ProgressView() }
        }
        .overlay {
            if isFilteringToDownloads, displayed.isEmpty {
                ContentUnavailableView(
                    "Nothing Downloaded",
                    systemImage: "arrow.down.circle",
                    description: Text("Albums you download appear here, and play with no server at all.")
                )
            }
        }
        .refreshable { await reload() }
        .task(id: LoadKey(sort: sort, scope: scope.generation, genre: genre, decade: decade)) {
            if !didApplyInitialSort {
                sort = initialSort
                didApplyInitialSort = true
            }
            await reload()
        }
    }

    /// Forced on when there is no server, because then it is simply the truth.
    private var isFilteringToDownloads: Bool {
        downloadedOnly || !appState.reachability.isOnline
    }

    private var displayed: [Album] {
        guard isFilteringToDownloads else { return albums }

        let downloaded = downloads.catalog.downloadedAlbums
        guard let genre else { return downloaded }
        return downloaded.filter { $0.genre?.caseInsensitiveCompare(genre) == .orderedSame }
    }

    private struct LoadKey: Equatable {
        let sort: AlbumSort
        let scope: Int
        let genre: String?
        let decade: Int?
    }

    private func reload() async {
        albums = []
        canLoadMore = true
        await loadMore()
    }

    private func loadMore() async {
        guard !isLoadingPage, canLoadMore else { return }
        isLoadingPage = true

        do {
            let offset = albums.count
            let currentSort = sort
            let currentGenre = genre
            let currentScope = scope.scope
            let client = appState.client

            // Only the first page is cached: offline, page 0 is the whole useful answer,
            // and stitching later pages into one entry buys nothing for the complexity.
            let page: [Album]
            if let decade {
                // The server filters on the *release* year while each row shows its
                // *original* year, so a 1979 record reissued in 1995 belongs here and
                // prints 1979. Not re-filtered locally, or those would vanish.
                page = try await client.albums(
                    fromYear: decade,
                    toYear: decade + 9,
                    size: pageSize,
                    offset: offset,
                    scope: currentScope
                )
            } else if offset == 0, currentGenre == nil {
                appState.beginLoadPass()
                let cached: [Album]? = await appState.cached(
                    CacheKey.albumList(currentSort.rawValue, currentScope.cacheKey)
                ) {
                    try await client.albums(
                        type: currentSort, size: 100, offset: 0, scope: currentScope
                    )
                }
                guard let cached else { throw SubsonicClient.ClientError.notConfigured }
                page = cached
            } else {
                page = try await client.albums(
                    type: currentSort,
                    size: pageSize,
                    offset: offset,
                    scope: currentScope,
                    genre: currentGenre
                )
            }
            albums.append(contentsOf: page)
            // A short page means the end. `random` never terminates meaningfully,
            // so stop after one page rather than looping forever.
            canLoadMore = page.count == pageSize && sort != .random
            error = nil
        } catch {
            self.error = error.localizedDescription
            canLoadMore = false
        }

        isLoadingPage = false
    }
}
