import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope

    @State private var model = HomeModel()
    /// -1 means both libraries. Its own setting, not the browsing scope.
    @AppStorage("mixes.folderID") private var mixFolderID = -1
    /// Plexamp's home editor: which shelves, in what order.
    @AppStorage("home.layout") private var layoutData: Data?
    @State private var isEditingLayout = false

    private var layout: HomeLayout { HomeLayout.restored(from: layoutData) }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.shelfSpacing) {
                    if model.isEmpty, model.hasLoaded {
                        ContentUnavailableView {
                            Label("Nothing to show", systemImage: "music.note.house")
                        } description: {
                            Text("Couldn't reach the server, or the library is empty.")
                        } actions: {
                            Button("Try again") {
                                Task { await model.load(appState: appState, scope: scope.scope) }
                            }
                        }
                        .padding(.top, 60)
                    } else {
                        ForEach(layout.visible) { hub in
                            shelf(hub)
                        }

                        // The bottom of the page asks for more mixes too, so scrolling
                        // down keeps the shelf growing without touching it sideways.
                        if !appState.mixes.mixes.isEmpty, appState.mixes.canLoadMore {
                            Color.clear
                                .frame(height: 1)
                                .task {
                                    appState.mixes.loadMore(appState: appState, scope: mixScope)
                                }
                        }
                    }
                }
                .padding(.vertical, Metrics.itemSpacing)
            }
            .navigationTitle("Home")
            .musicDestinations()
            .offlineBanner()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // Library Radio: the whole library shuffled, and it never runs out.
                    Button {
                        appState.stations.play(.library)
                    } label: {
                        Image(systemName: "shuffle")
                    }
                    .accessibilityLabel("Shuffle library")
                }
                ToolbarItem(placement: .topBarTrailing) { LibraryScopeMenu() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Edit Home", systemImage: "rectangle.3.group") {
                            isEditingLayout = true
                        }
                        NavigationLink(value: Destination.settings) {
                            Label("Settings", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $isEditingLayout) {
                HomeEditorView(layoutData: $layoutData)
            }
            .refreshable {
                await model.load(appState: appState, scope: scope.scope)
            }
            .task(id: scope.generation) {
                await model.load(appState: appState, scope: scope.scope)
            }
            // Separate from the shelves above: this one is built from a dozen requests
            // and only once a day, so it must not hold up the rest of Home or be redone
            // by every pull-to-refresh.
            .task(id: mixFolderID) {
                appState.mixes.load(appState: appState, scope: mixScope)
            }
        }
    }

    @ViewBuilder
    private func shelf(_ hub: HomeHub) -> some View {
        switch hub {
        case .madeForYou: mixShelf
        case .stations: StationsShelf()
        case .recentlyPlayed: albumShelf("Recently Played", model.recentlyPlayed, sort: .recent)
        case .recentlyAdded: albumShelf("Recently Added", model.recentlyAdded, sort: .newest)
        case .favourites: favoriteSongs
        case .mostPlayed: albumShelf("Most Played", model.mostPlayed, sort: .frequent)
        case .forgottenFavourites: forgottenFavourites
        case .onThisDay: onThisDay
        case .moreInGenre:
            if let genre = model.moreInGenre {
                albumShelf("More in \(genre.name)", genre.albums, seeAll: .genre(genre.name))
            }
        case .bestOfLastYear:
            albumShelf("Best of \(model.lastYear)", model.bestOfLastYear,
                       seeAll: .albumCollection(title: "Best of \(model.lastYear)", albums: model.bestOfLastYear))
        case .notPlayedLately:
            albumShelf("Haven't Played Lately", model.notPlayedLately,
                       seeAll: .albumCollection(title: "Haven't Played Lately", albums: model.notPlayedLately))
        }
    }

    /// Plexamp's On This Day: albums released on today's date in years past, each with
    /// how long ago.
    @ViewBuilder
    private var onThisDay: some View {
        if !model.onThisDay.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.headerToContent) {
                ShelfHeader(title: "On This Day")

                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Metrics.itemSpacing) {
                        ForEach(model.onThisDay, id: \.album.id) { entry in
                            NavigationLink(value: Destination.album(AlbumRef(entry.album))) {
                                VStack(alignment: .leading, spacing: 4) {
                                    AlbumCard(album: entry.album)
                                    Text(entry.years == 1 ? "1 year ago today" : "\(entry.years) years ago today")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(Color.appTint)
                                }
                                .frame(width: Metrics.cardWidth)
                            }
                            .buttonStyle(.plain)
                            .albumMenu(entry.album)
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

    /// The counterweight to every other shelf on this screen.
    ///
    /// Recently played, recently added and most played all show the same small corner of a
    /// library where 95% of tracks have never been played once. This one shows what has
    /// been starred and then left alone, which is the only shelf here that can send you
    /// somewhere you have not already been.
    @ViewBuilder
    private var forgottenFavourites: some View {
        if !model.forgotten.songs.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.headerToContent) {
                ShelfHeader(title: "Forgotten Favourites", seeAll: .rediscover)

                VStack(spacing: 0) {
                    ForEach(Array(model.forgotten.songs.enumerated()), id: \.element.id) { index, song in
                        PlayableSongRow(
                            songs: model.forgotten.songs,
                            index: index,
                            source: "Forgotten Favourites",
                            trailing: Rediscovery.lastPlayedText(model.forgotten.lastPlayed[song.id])
                        )
                        .padding(.horizontal, Metrics.gutter)
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    /// The one shelf here that could not exist without the app's own play log: the
    /// server records how many times a track was played, never when.
    /// The mixes have their own library choice, separate from the browsing scope in the
    /// toolbar: "recommend from both libraries while I browse just one" is a reasonable
    /// thing to want, and it is the mixes people care about scoping.
    private var mixScope: LibraryScope {
        guard mixFolderID != -1,
              let folder = scope.folders.first(where: { $0.id == mixFolderID })
        else { return .all }
        return .folder(id: folder.id, name: folder.name)
    }

    @ViewBuilder
    private var mixScopeMenu: some View {
        if scope.isSwitchable {
            Menu {
                Picker("Library", selection: $mixFolderID) {
                    Text("Both Libraries").tag(-1)
                    ForEach(scope.folders) { folder in
                        Text(folder.name).tag(folder.id)
                    }
                }
            } label: {
                Text(mixFolderID == -1 ? "Both" : mixScope.shortName)
                    .font(.subheadline)
            }
        }
    }

    @ViewBuilder
    private var mixShelf: some View {
        if appState.mixes.mixes.isEmpty, appState.mixes.isBuilding {
            // The first build is a dozen requests, and an absent shelf is
            // indistinguishable from a missing feature.
            VStack(alignment: .leading, spacing: Metrics.headerToContent) {
                ShelfHeader(title: "Made for You", seeAll: .dailyMixes) { mixScopeMenu }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Building today's mixes…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Metrics.gutter)
            }
        } else if !appState.mixes.mixes.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.headerToContent) {
                ShelfHeader(title: "Made for You", seeAll: .dailyMixes) { mixScopeMenu }

                ScrollView(.horizontal) {
                    LazyHStack(spacing: Metrics.itemSpacing) {
                        ForEach(appState.mixes.mixes) { mix in
                            NavigationLink(value: Destination.dailyMix(mix.id)) {
                                VStack(alignment: .leading, spacing: 6) {
                                    MixTile(covers: mix.covers, size: .card)
                                        .frame(width: Metrics.cardWidth, height: Metrics.cardWidth)
                                    Text(mix.title)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                    Text(mix.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(width: Metrics.cardWidth, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }

                        // Reaching the end of the row builds more. A sentinel rather than
                        // scroll maths: `.task` on a lazily created view fires exactly
                        // when it comes into view and cancels correctly.
                        if appState.mixes.canLoadMore {
                            ProgressView()
                                .frame(width: 80, height: Metrics.cardWidth)
                                .task {
                                    appState.mixes.loadMore(appState: appState, scope: mixScope)
                                }
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

    private func albumShelf(_ title: String, _ albums: [Album], sort: AlbumSort) -> some View {
        albumShelf(title, albums, seeAll: .albums(sort))
    }

    @ViewBuilder
    private func albumShelf(_ title: String, _ albums: [Album], seeAll: Destination?) -> some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.headerToContent) {
                ShelfHeader(title: title, seeAll: seeAll)

                ScrollView(.horizontal) {
                    LazyHStack(spacing: Metrics.itemSpacing) {
                        ForEach(albums) { album in
                            NavigationLink(value: Destination.album(AlbumRef(album))) {
                                AlbumCard(album: album)
                                    .frame(width: Metrics.cardWidth)
                            }
                            .buttonStyle(.plain)
                            .albumMenu(album)
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

    /// Deliberately vertical: it breaks the carousel rhythm, and it is the only
    /// shelf you can act on without a second tap.
    @ViewBuilder
    private var favoriteSongs: some View {
        if !model.favoriteSongs.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.headerToContent) {
                ShelfHeader(title: "Favourites", seeAll: .favorites)

                // `PlayableSongRow`, not a bare `SongRow`: these rows had a
                // `contentShape` and nothing to receive the tap, so unlike every other
                // song list in the app they did nothing at all -- no play, no menu.
                //
                // Swipe actions still will not work here, because `.swipeActions` only
                // functions inside a `List` and Home is a `ScrollView`. Tap and
                // long-press do, which is the same trade `ArtistDetailView` makes for its
                // Top Songs block. Not worth turning Home into a `List` for.
                VStack(spacing: 0) {
                    ForEach(Array(model.favoriteSongs.enumerated()), id: \.element.id) { index, _ in
                        PlayableSongRow(
                            songs: model.favoriteSongs,
                            index: index,
                            source: "Favourites"
                        )
                        .padding(.horizontal, Metrics.gutter)
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }
}

struct ShelfHeader<Accessory: View>: View {
    let title: String
    var seeAll: Destination?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.semibold))
            Spacer()
            accessory()
            if let seeAll {
                NavigationLink(value: seeAll) {
                    Text("See All")
                        .font(.subheadline)
                }
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }
}

extension ShelfHeader where Accessory == EmptyView {
    init(title: String, seeAll: Destination? = nil) {
        self.init(title: title, seeAll: seeAll) { EmptyView() }
    }
}

@MainActor
@Observable
final class HomeModel {
    var recentlyPlayed: [Album] = []
    var recentlyAdded: [Album] = []
    var mostPlayed: [Album] = []
    var favoriteSongs: [Song] = []
    var forgotten = Rediscovery.Forgotten()
    var onThisDay: [(album: Album, years: Int)] = []
    var bestOfLastYear: [Album] = []
    var notPlayedLately: [Album] = []
    var moreInGenre: (name: String, albums: [Album])?
    var hasLoaded = false

    var lastYear: Int { Calendar.current.component(.year, from: .now) - 1 }

    var isEmpty: Bool {
        recentlyPlayed.isEmpty && recentlyAdded.isEmpty
            && mostPlayed.isEmpty && favoriteSongs.isEmpty && forgotten.songs.isEmpty
            && onThisDay.isEmpty && bestOfLastYear.isEmpty && notPlayedLately.isEmpty
    }

    /// Shelves load concurrently and a failing shelf is simply dropped: one dead
    /// endpoint should not replace the whole screen with an error.
    ///
    /// Each goes through `appState.cached`, so Home is the same screen offline as on --
    /// which it was not before: every shelf simply came back empty, and an empty Home
    /// reads as a broken app rather than an offline one.
    func load(appState: AppState, scope: LibraryScope) async {
        appState.beginLoadPass()

        let client = appState.client
        let key = scope.cacheKey

        async let played: [Album]? = appState.cached(CacheKey.shelf("recent", key)) {
            try await client.albums(type: .recent, size: 12, scope: scope)
        }
        async let added: [Album]? = appState.cached(CacheKey.shelf("newest", key)) {
            try await client.albums(type: .newest, size: 12, scope: scope)
        }
        async let frequent: [Album]? = appState.cached(CacheKey.shelf("frequent", key)) {
            try await client.albums(type: .frequent, size: 12, scope: scope)
        }
        async let starred: Starred2? = appState.cached(CacheKey.starred(key)) {
            try await client.starred(scope: scope)
        }
        // Not cached: it is derived from two calls, and offline the starred list it is
        // built from is already served from the cache above.
        async let neglected = Rediscovery.forgottenFavourites(appState: appState, scope: scope, limit: 3)

        recentlyPlayed = await played ?? []
        recentlyAdded = await added ?? []
        mostPlayed = await frequent ?? []
        favoriteSongs = Array((await starred?.songs ?? []).prefix(4))
        forgotten = await neglected
        hasLoaded = true

        // The shelves cut from the whole album list. After the rest, so they never hold
        // Home up; the list itself is kept on disk and only refetched every few hours.
        if let genre = recentlyPlayed.lazy.compactMap(\.genre).first(where: { !$0.isEmpty }) {
            let seen = Set(recentlyPlayed.map(\.id))
            let albums = (try? await client.albums(type: .random, size: 20, scope: scope, genre: genre)) ?? []
            let fresh = albums.filter { !seen.contains($0.id) }
            moreInGenre = fresh.isEmpty ? nil : (genre, fresh)
        }

        let index = appState.libraryIndex
        await index.ensureLoaded(scope: scope)
        onThisDay = LibraryFacets.onThisDay(index.albums, on: .now)
        bestOfLastYear = LibraryFacets.bestOf(year: lastYear, in: index.albums)
        let sixMonthsAgo = Calendar.current.date(byAdding: .month, value: -6, to: .now) ?? .now
        notPlayedLately = LibraryFacets.notPlayedSince(sixMonthsAgo, in: index.albums)
    }
}

/// Plexamp's home editor: show or hide each shelf, drag to reorder, reset.
struct HomeEditorView: View {
    @Binding var layoutData: Data?
    @Environment(\.dismiss) private var dismiss

    @State private var layout = HomeLayout.default

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(layout.order) { hub in
                        Toggle(hub.title, isOn: Binding(
                            get: { layout.isVisible(hub) },
                            set: { layout.setVisible($0, hub) }
                        ))
                    }
                    .onMove { layout.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    Text("Drag to reorder. Shelves with nothing to show stay out of the way on their own.")
                }

                Section {
                    Button("Reset to Default") { layout = .default }
                        .disabled(layout == .default)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Edit Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        layoutData = layout.encoded
                        dismiss()
                    }
                }
            }
        }
        .onAppear { layout = HomeLayout.restored(from: layoutData) }
    }
}
