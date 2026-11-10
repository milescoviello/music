import SwiftUI

struct SearchView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope

    @State private var query = ""
    @State private var outcome: SearchService.Outcome?
    @State private var isSearching = false
    /// The last search reached neither the query nor its correction: offline, or the
    /// server is down. Said so, rather than shown as an empty list.
    @State private var failed = false
    @State private var genres: [Genre] = []
    /// Bound so that opening a result can be noticed: that is when a search is worth
    /// keeping in Recent.
    @State private var path = NavigationPath()
    /// The library, or YouTube: music videos and songs the library does not have.
    @State private var source = Source.library

    enum Source: Hashable { case library, youtube }

    private var results: SearchResult3? { outcome?.results }

    private let genreColumns = [
        GridItem(.flexible(), spacing: Metrics.itemSpacing),
        GridItem(.flexible(), spacing: Metrics.itemSpacing),
    ]

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if source == .youtube {
                    YouTubeResultsView(query: query, onUse: recordQuery)
                } else if query.isEmpty {
                    idleState
                } else if failed, !isSearching {
                    ContentUnavailableView {
                        Label("Can’t Reach the Server", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text("Search needs the server. Downloads are in Library.")
                    }
                } else if let outcome, outcome.isOffline, outcome.isEmpty, !isSearching {
                    ContentUnavailableView {
                        Label("Can’t Reach the Server", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text("Nothing downloaded matches “\(query)”.")
                    }
                } else if let outcome, outcome.isEmpty, !isSearching {
                    // The one moment a request button is genuinely useful: you have just
                    // established that the library does not have this.
                    ContentUnavailableView {
                        Label("No Results", systemImage: "magnifyingglass")
                    } description: {
                        Text("Nothing in your library matches “\(query)”.")
                    } actions: {
                        NavigationLink(value: Destination.requestMusic(query)) {
                            Label("Ask Hermes to find it", systemImage: "arrow.down.heart")
                        }
                        .buttonStyle(.borderedProminent)

                        // Metadata search has just failed, which is exactly when a
                        // half-remembered lyric is the only thing left to go on.
                        NavigationLink(value: Destination.lyricSearch(query)) {
                            Label("Search lyrics instead", systemImage: "text.magnifyingglass")
                        }
                    }
                } else {
                    resultsList
                }
            }
            .navigationTitle("Search")
            .safeAreaInset(edge: .top, spacing: 0) { sourcePicker }
            .musicDestinations()
            .offlineBanner()
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Artists, Albums, Songs"
            )
            // `.searchScopes` rather than the toolbar menu used elsewhere: it is the
            // control iOS already puts under a search field, and a second menu beside
            // the field would be one affordance too many. Same store either way.
            .searchScopes(
                Binding(get: { scope.scope }, set: { scope.scope = $0 }),
                activation: .onSearchPresentation
            ) {
                ForEach(scope.options, id: \.self) { option in
                    Text(option.shortName).tag(option)
                }
            }
            .onSubmit(of: .search) {
                appState.recentSearches.record(query)
            }
            .scrollDismissesKeyboard(.immediately)
            .task(id: SearchKey(query: query, scope: scope.generation, source: source)) {
                // YouTube's side searches for itself; the library is left alone meanwhile.
                guard source == .library else { return }
                await search()
            }
            // Fetches the words that put a misspelled search right, if this phone does not
            // have them yet or they are a day old.
            .task { appState.search.prepare() }
            .onChange(of: path.count) { old, new in
                if old == 0, new > 0 { appState.recentSearches.record(query) }
            }
            .task(id: scope.generation) {
                genres = ((try? await appState.client.genres(scope: scope.scope)) ?? [])
                    .sorted { ($0.albumCount ?? 0) > ($1.albumCount ?? 0) }
            }
        }
    }

    /// Genres belong here rather than on Home: a genre is a lookup facet, not a
    /// recommendation.
    private var idleState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.headerToContent) {
                if !appState.recentSearches.terms.isEmpty {
                    HStack {
                        Text("Recent")
                            .font(.title3.weight(.semibold))
                        Spacer()
                        Button("Clear") { appState.recentSearches.clear() }
                            .font(.footnote)
                    }
                    .padding(.horizontal, Metrics.gutter)

                    VStack(spacing: 0) {
                        ForEach(appState.recentSearches.terms, id: \.self) { term in
                            Button {
                                query = term
                            } label: {
                                HStack(spacing: Metrics.itemSpacing) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .foregroundStyle(.tertiary)
                                    Text(term)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 10)
                                .padding(.horizontal, Metrics.gutter)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Text("Browse Genres")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, Metrics.gutter)

                LazyVGrid(columns: genreColumns, spacing: Metrics.itemSpacing) {
                    ForEach(genres.prefix(30)) { genre in
                        NavigationLink(value: Destination.genre(genre.value)) {
                            Text(genre.value)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, minHeight: 72)
                                .padding(.horizontal, 8)
                                .background(.quaternary, in: RoundedRectangle(
                                    cornerRadius: Metrics.radiusCard, style: .continuous
                                ))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Metrics.gutter)

                Text("Browse by Decade")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.top, Metrics.itemSpacing)

                // Fixed rather than derived: the library runs 1963 to 2025, so every one
                // of these has records behind it, and asking the server which decades
                // exist would be seven requests to render a row of chips.
                ScrollView(.horizontal) {
                    HStack(spacing: Metrics.itemSpacing) {
                        ForEach(Array(stride(from: 1960, through: 2020, by: 10)), id: \.self) { start in
                            NavigationLink(value: Destination.decade(start)) {
                                Text("\(String(start))s")
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 18)
                                    .frame(minHeight: 44)
                                    .background(.quaternary, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.vertical, Metrics.itemSpacing)
        }
    }

    private var resultsList: some View {
        List {
            if let outcome, outcome.isOffline {
                Label("Offline · showing what is downloaded", systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }

            if let outcome, let correction = outcome.correction {
                // Said, so a result that is not what was typed is not a mystery.
                Text(outcome.isCorrectionOnly
                    ? "Showing results for “\(correction)”"
                    : "Including results for “\(correction)”")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }

            if let outcome, outcome.isCorrectionOnly {
                // Nothing matched what was typed, so these are the library's nearest words
                // -- which for an artist not in the library ("nerio") is something else
                // entirely. Asking for it has to stay a tap away, as it is under No Results.
                NavigationLink(value: Destination.requestMusic(outcome.query)) {
                    Label("Ask Hermes to find “\(outcome.query)”", systemImage: "arrow.down.heart")
                }
            }

            if let outcome, let top = SearchRanking.topResult(for: outcome.rankedFor, in: outcome.results) {
                Section("Top Result") {
                    topResultRow(top)
                }
            }

            let playlists = matchingPlaylists
            if !playlists.isEmpty {
                Section("Playlists") {
                    ForEach(playlists.prefix(4)) { playlist in
                        NavigationLink(value: Destination.playlist(PlaylistRef(playlist))) {
                            HStack(spacing: Metrics.itemSpacing) {
                                ArtworkImage(id: playlist.coverArt, size: .thumb, cornerRadius: Metrics.radiusThumb)
                                    .frame(width: Metrics.thumbSmall, height: Metrics.thumbSmall)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name).lineLimit(1)
                                    if let count = playlist.songCount {
                                        Text("\(count) songs").font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if let artists = results?.artists, !artists.isEmpty {
                Section("Artists") {
                    ForEach(artists.prefix(4)) { artist in
                        NavigationLink(value: Destination.artist(ArtistRef(artist))) {
                            HStack(spacing: Metrics.itemSpacing) {
                                ArtistArtwork(
                                    id: artist.coverArt,
                                    diameter: Metrics.thumbSmall,
                                    initials: artist.name.monogram
                                )
                                Text(artist.name).lineLimit(1)
                            }
                        }
                    }
                }
            }

            if let albums = results?.albums, !albums.isEmpty {
                Section("Albums") {
                    ForEach(albums.prefix(6)) { album in
                        NavigationLink(value: Destination.album(AlbumRef(album))) {
                            HStack(spacing: Metrics.itemSpacing) {
                                ArtworkImage(
                                    id: album.coverArt,
                                    size: .thumb,
                                    cornerRadius: Metrics.radiusThumb
                                )
                                .frame(width: Metrics.thumbSmall, height: Metrics.thumbSmall)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.name).lineLimit(1)
                                    if let artist = album.artist {
                                        Text(artist)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                        .albumFavorite(album)
                    }
                }
            }

            if let songs = results?.songs, !songs.isEmpty {
                // Capped at 20, then played as that list: results past the cap are
                // not on screen, so queueing them would be a surprise.
                let visible = Array(songs.prefix(20))
                Section("Songs") {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, _ in
                        PlayableSongRow(songs: visible, index: index, source: "Search", onPlay: recordQuery)
                    }
                }
            }

            if let lyrics = outcome?.lyrics, !lyrics.isEmpty {
                Section("Lyrics") {
                    ForEach(lyrics) { match in
                        lyricRow(match)
                    }
                }
            }

            // A trailing row rather than a second search field: metadata results and
            // lyric results answer different questions, and the second one costs an
            // agent run, so it stays opt-in.
            Section {
                NavigationLink(value: Destination.lyricSearch(query)) {
                    Label("Search lyrics for “\(query)”", systemImage: "text.magnifyingglass")
                }
            }
        }
        .listStyle(.plain)
        // Opening or playing a result is what records the search, in `onChange(of:
        // path.count)` and the song rows' `onPlay`. A tap gesture over the whole list did
        // it before, and it stopped album and artist rows opening at all: in a List those
        // open by row selection, which a tap gesture laid over the list takes first.
        .overlay {
            if isSearching, results == nil { ProgressView() }
        }
    }

    /// Playlists are not part of `search3`, so they are matched here, from the list the
    /// app already has.
    private var matchingPlaylists: [Playlist] {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        guard wanted.count >= 2 else { return [] }
        return appState.playlistStore.playlists.filter { $0.name.localizedCaseInsensitiveContains(wanted) }
    }

    /// Plexamp's Top Result: bigger than the rows below, and a tap away from playing.
    @ViewBuilder
    private func topResultRow(_ top: SearchRanking.TopResult) -> some View {
        switch top {
        case let .artist(artist):
            NavigationLink(value: Destination.artist(ArtistRef(artist))) {
                HStack(spacing: Metrics.itemSpacing) {
                    ArtistArtwork(id: artist.coverArt, diameter: 72, initials: artist.name.monogram)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(artist.name).font(.title3.weight(.semibold)).lineLimit(1)
                        Text("Artist").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        appState.stations.play(.artistMix(ids: [artist.id], names: [artist.name]))
                    } label: {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Play \(artist.name) Radio")
                }
            }
        case let .album(album):
            NavigationLink(value: Destination.album(AlbumRef(album))) {
                HStack(spacing: Metrics.itemSpacing) {
                    ArtworkImage(id: album.coverArt, size: .thumb, cornerRadius: Metrics.radiusThumb)
                        .frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(album.name).font(.title3.weight(.semibold)).lineLimit(1)
                        Text(["Album", album.artist, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .albumFavorite(album)
        case let .song(song):
            PlayableSongRow(songs: [song], index: 0, source: "Search", onPlay: recordQuery)
        }
    }

    private func recordQuery() {
        appState.recentSearches.record(query)
    }

    /// The song, and under it the line that matched, so it is plain why it is here.
    private func lyricRow(_ match: SonicService.LyricMatch) -> some View {
        Button {
            appState.player.play(songs: [match.song], startingAt: 0, source: "Search")
            recordQuery()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                SongRow(
                    song: match.song,
                    style: .withArtwork,
                    isCurrent: match.song.isSameRecording(as: appState.player.currentSong),
                    trailing: nil
                )
                Text("“\(match.line)”")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            SongMenu(song: match.song)
        }
    }

    private struct SearchKey: Equatable {
        let query: String
        let scope: Int
        let source: Source
    }

    /// Library | YouTube, under the search field. Only while the sonic service answers,
    /// since YouTube comes through it -- or while YouTube is chosen, so it can be left.
    @ViewBuilder
    private var sourcePicker: some View {
        if appState.video.isAvailable || source == .youtube {
            Picker("Search", selection: $source) {
                Text("Library").tag(Source.library)
                Text("YouTube").tag(Source.youtube)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    /// The debounce is the `.task(id:)` itself: a keystroke cancels the previous
    /// task, so sleeping at the top is all that is needed. No Combine, no timers.
    ///
    /// One letter is searched too: a single letter can be a whole song title ("Q."),
    /// and the two-letter minimum this had meant it could never be found.
    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        guard !trimmed.isEmpty else {
            outcome = nil
            failed = false
            isSearching = false
            return
        }

        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }

        isSearching = true
        let found = await appState.search.search(trimmed, scope: scope.scope)
        // A newer keystroke has started its own search; this one's answer is stale.
        guard !Task.isCancelled else { return }
        outcome = found
        failed = found == nil
        isSearching = false
    }
}
