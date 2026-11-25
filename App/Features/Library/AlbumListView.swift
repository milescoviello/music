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
    /// Which list a page belongs to. Bumped by every reload, so a page still on its way
    /// for the old sort is dropped instead of landing in the new list.
    @State private var generation = 0

    private let columns = Metrics.albumGrid

    private var pageSize: Int { 100 }

    var body: some View {
        ScrollViewReader { proxy in
            grid
                .overlay(alignment: .trailing) {
                    // The whole library, so any letter can be jumped to.
                    if let lettered = letteredAlbums, lettered.count > 40 {
                        let firsts = firstAlbumByLetter(lettered)
                        AlphabetRail(available: Set(firsts.keys)) { letter in
                            guard let target = firsts[letter] else { return }
                            proxy.scrollTo(target, anchor: .top)
                        }
                        .padding(.trailing, 2)
                        .padding(.vertical, Metrics.itemSpacing)
                    }
                }
        }
    }

    /// A–Z of the whole library, from the index (`LibraryIndex`) and sorted here, once it
    /// is in: the server's pages sort by the name as typed, and come a hundred at a time, so
    /// neither the order nor a letter rail could be right from them. Sorted once for each
    /// change, not for every redraw: two thousand names.
    @State private var letteredAlbums: [Album]?

    private struct LetterKey: Equatable {
        let wanted: Bool
        let scope: Int
        let ready: Bool
        let count: Int
    }

    private var letterKey: LetterKey {
        let index = appState.libraryIndex
        return LetterKey(
            wanted: sort == .alphabeticalByName && genre == nil && decade == nil && !isFilteringToDownloads,
            scope: scope.generation,
            ready: index.readiness(for: scope.scope) == .ready,
            count: index.albums.count
        )
    }

    private func firstAlbumByLetter(_ albums: [Album]) -> [String: String] {
        var firsts: [String: String] = [:]
        for album in albums {
            let letter = NameOrder.letter(album.name)
            if firsts[letter] == nil { firsts[letter] = album.id }
        }
        return firsts
    }

    private var grid: some View {
        ScrollView {
            if let error, albums.isEmpty, letteredAlbums == nil {
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
                // Clear of the letter rail beside it.
                .padding(.trailing, letteredAlbums == nil ? 0 : 8)

                // A sentinel rather than scroll-offset maths: `.task` on a lazily
                // created view is cancellation-correct and fires exactly when the
                // user reaches the end.
                // Never paged while filtering to downloads: the list is the catalog, and
                // it is already whole.
                if canLoadMore, !albums.isEmpty, !isFilteringToDownloads, letteredAlbums == nil {
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
            if sort == .alphabeticalByName, genre == nil, decade == nil {
                await appState.libraryIndex.ensureLoaded(scope: scope.scope)
            }
        }
        .task(id: letterKey) {
            let key = letterKey
            letteredAlbums = key.wanted && key.ready ? NameOrder.sorted(appState.libraryIndex.albums) : nil
        }
        .task(id: LoadKey(sort: sort, scope: scope.generation, genre: genre, decade: decade)) {
            if !didApplyInitialSort {
                sort = initialSort
                didApplyInitialSort = true
            }
            // Again only when what is listed changed. SwiftUI runs this every time the
            // screen comes back into view, after an album opened from it was closed, and
            // reloading then emptied the grid and threw away how far it had been scrolled.
            let key = LoadKey(sort: sort, scope: scope.generation, genre: genre, decade: decade)
            guard key != loadedKey else { return }
            await reload()
            if !Task.isCancelled { loadedKey = key }
        }
    }

    /// Forced on when there is no server, because then it is simply the truth.
    private var isFilteringToDownloads: Bool {
        downloadedOnly || !appState.reachability.isOnline
    }

    /// One of each album: the library's two folders hold many twice. `albums` stays as
    /// the server sent it, since the next page's offset is counted in its rows.
    private var displayed: [Album] {
        if let letteredAlbums { return letteredAlbums }
        // Until the index is in, the pages there are, in the same order.
        if sort == .alphabeticalByName, !isFilteringToDownloads { return NameOrder.sorted(SearchRanking.oneOfEach(albums)) }
        guard isFilteringToDownloads else { return SearchRanking.oneOfEach(albums) }

        let downloaded = downloads.catalog.downloadedAlbums
        guard let genre else { return downloaded }
        return downloaded.filter { $0.hasGenre(genre) }
    }

    @State private var loadedKey: LoadKey?

    private struct LoadKey: Equatable {
        let sort: AlbumSort
        let scope: Int
        let genre: String?
        let decade: Int?
    }

    /// Always starts a fresh list, even with a page still loading for the old one.
    ///
    /// It used to be turned away by that page's `isLoadingPage`. Changing the sort while a
    /// page loaded -- or opening a list whose first act is to set its initial sort, which
    /// restarts the load at once -- left the new list waiting on the old request, which
    /// was then cancelled: an empty list reading "Can't load albums", or the old sort's
    /// albums under the new sort's name.
    private func reload() async {
        generation += 1
        albums = []
        canLoadMore = true
        error = nil
        isLoadingPage = false
        await loadMore()
    }

    private func loadMore() async {
        guard !isLoadingPage, canLoadMore else { return }
        isLoadingPage = true
        let started = generation
        // Only the list that started this load may say it is over.
        defer { if started == generation { isLoadingPage = false } }

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
            guard started == generation else { return }
            albums.append(contentsOf: page)
            // A short page means the end. `random` never terminates meaningfully,
            // so stop after one page rather than looping forever.
            canLoadMore = page.count == pageSize && sort != .random
            error = nil
        } catch {
            // A load given up on -- this view's task cancelled by a newer one -- is not
            // a failure to show.
            guard started == generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription
            canLoadMore = false
        }
    }
}
