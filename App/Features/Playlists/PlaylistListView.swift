import PhotosUI
import SwiftUI

struct PlaylistListView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaylistStore.self) private var store
    @Environment(DownloadCenter.self) private var downloads

    @State private var isCreating = false
    @State private var editing: Playlist?
    @State private var deleting: Playlist?

    private var playlists: [Playlist] { store.playlists }
    private var isLoading: Bool { store.isLoading }

    private var arrangement: PlaylistArrangement { appState.playlistArrangement }

    /// Drag handles showing, for moving pinned playlists and the rest. Off otherwise, so
    /// rows can be swiped to pin.
    @State private var isArranging = false

    var body: some View {
        let split = arrangement.arranged(playlists)
        List {
            // His main ones, first and in his own order. Swipe right or long-press to pin.
            if !split.pinned.isEmpty {
                Section("Pinned") {
                    ForEach(split.pinned) { playlist in
                        row(playlist)
                    }
                    .onMove { arrangement.movePinned(from: $0, to: $1, shown: split.pinned) }
                }
            }

            Section {
                ForEach(split.rest) { playlist in
                    row(playlist)
                }
                // Moving one by hand makes the order his own: My Order in the sort menu.
                .onMove { arrangement.moveRest(from: $0, to: $1, shown: split.rest) }
            } header: {
                if !split.pinned.isEmpty { Text("Playlists") }
            } footer: {
                if !playlists.isEmpty {
                    // Stated once, quietly: the server has no folder parameter for
                    // playlists, so the library switch cannot apply here.
                    Text("Playlists are shown from every library.")
                }
            }
        }
        .listStyle(.plain)
        .playerClearance()
        .navigationTitle("Playlists")
        .environment(\.editMode, .constant(isArranging ? .active : .inactive))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(isArranging ? "Done" : "Edit") {
                    withAnimation { isArranging.toggle() }
                }
                .disabled(playlists.count < 2)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: Binding(
                        get: { arrangement.sort },
                        set: { arrangement.sort = $0 }
                    )) {
                        ForEach(PlaylistArrangement.Sort.allCases) { sort in
                            Text(sort.title).tag(sort)
                        }
                    }
                } label: {
                    Label(arrangement.sort.title, systemImage: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Sort playlists")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New Playlist", systemImage: "plus") { isCreating = true }
                    NavigationLink(value: Destination.vibePlaylist) {
                        Label("Ask Hermes for One", systemImage: "sparkles")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New playlist")
            }
        }
        .sheet(isPresented: $isCreating) {
            NewPlaylistSheet(songs: [])
        }
        .sheet(item: $editing) { playlist in
            EditPlaylistSheet(playlist: playlist)
        }
        .confirmationDialog(
            deleting.map { "Delete “\($0.name)”?" } ?? "",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Playlist", role: .destructive) {
                if let playlist = deleting {
                    Task { await store.delete(playlist) }
                }
                deleting = nil
            }
        } message: {
            Text("The songs stay in your library.")
        }
        .overlay {
            if isLoading, playlists.isEmpty { ProgressView() }
        }
        .overlay {
            if !isLoading, playlists.isEmpty {
                ContentUnavailableView(
                    "No Playlists",
                    systemImage: "music.note.list",
                    description: Text("Tap + to make one, or add songs from any list.")
                )
            }
        }
        .refreshable { await store.load() }
        .task { await store.refreshIfStale() }
    }

    /// The same toggle as the download button on the playlist's own screen: Download,
    /// or Remove Download once any of it is here or on its way.
    @ViewBuilder
    private func downloadItems(for playlist: Playlist) -> some View {
        if !downloads.hasDownload(group: playlist.id) {
            Button("Download", systemImage: "arrow.down.circle") {
                withSongs(playlist) { songs in
                    downloads.download(songs, groupID: playlist.id, groupName: playlist.name)
                }
            }
        } else {
            Button("Remove Download", systemImage: "trash", role: .destructive) {
                appState.playlistSync.stopSyncing(groupID: playlist.id)
                downloads.removeGroup(playlist.id)
            }
        }
    }

    /// A row only has the playlist, not its tracks, so they are fetched first: from the
    /// server, or the saved copy's songs on this phone when it doesn't answer.
    private func withSongs(_ playlist: Playlist, _ action: @escaping @MainActor ([Song]) -> Void) {
        Task {
            let songs = await appState.playlistSongsToPlay(playlist.id)
            guard !songs.isEmpty else { return }
            action(songs)
        }
    }

    /// Works offline: the saved playlist's songs that are on the phone.
    private func play(_ playlist: Playlist, shuffled: Bool = false) {
        Task {
            let songs = await appState.playlistSongsToPlay(playlist.id)
            guard !songs.isEmpty else { return }
            appState.player.play(
                songs: songs, startingAt: 0, source: playlist.name, shuffled: shuffled
            )
        }
    }

    private func row(_ playlist: Playlist) -> some View {
        NavigationLink(value: Destination.playlist(PlaylistRef(playlist))) {
            HStack(spacing: Metrics.itemSpacing) {
                ArtworkImage(
                    id: playlist.coverArt,
                    size: .thumb,
                    cornerRadius: Metrics.radiusThumb,
                    playlistID: playlist.id
                )
                .frame(width: Metrics.thumbPlaylist, height: Metrics.thumbPlaylist)

                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .lineLimit(1)
                    Text(subtitle(for: playlist))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 64)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                withAnimation { arrangement.togglePin(playlist) }
            } label: {
                if arrangement.isPinned(playlist) {
                    Label("Unpin", systemImage: "pin.slash")
                } else {
                    Label("Pin", systemImage: "pin")
                }
            }
            .tint(.orange)
        }
        .contextMenu {
            Button(
                arrangement.isPinned(playlist) ? "Unpin" : "Pin to Top",
                systemImage: arrangement.isPinned(playlist) ? "pin.slash" : "pin"
            ) {
                withAnimation { arrangement.togglePin(playlist) }
            }
            Divider()
            Button("Play", systemImage: "play.fill") { play(playlist) }
            Button("Shuffle", systemImage: "shuffle") {
                play(playlist, shuffled: true)
            }
            Divider()
            Button("Play Next", systemImage: "text.insert") {
                withSongs(playlist) { appState.player.playNext($0) }
            }
            if appState.player.canAddToUpNext {
                Button("Add to Up Next", systemImage: "list.bullet.indent") {
                    withSongs(playlist) { appState.player.addToUpNext($0) }
                }
            }
            Button("Add to Queue", systemImage: "text.append") {
                withSongs(playlist) { appState.player.append($0) }
            }
            Divider()
            downloadItems(for: playlist)
            Divider()
            Button("Rename…", systemImage: "pencil") { editing = playlist }
            Button("Delete", systemImage: "trash", role: .destructive) {
                deleting = playlist
            }
        }
    }

    private func subtitle(for playlist: Playlist) -> String {
        var parts: [String] = []
        if let count = playlist.songCount { parts.append("\(count) songs") }
        if let duration = playlist.duration { parts.append(duration.asLongDuration) }
        return parts.joined(separator: " · ")
    }

}

struct PlaylistDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaylistStore.self) private var store
    @Environment(LibraryScopeStore.self) private var scope
    @Environment(PlaylistArtwork.self) private var artwork

    let playlist: PlaylistRef

    @State private var detail: PlaylistDetail?

    /// The name as the store has it now, not as it was when the screen opened: renamed
    /// from here, the title, header and description kept the old ones.
    private var name: String {
        store.playlists.first(where: { $0.id == playlist.id })?.name ?? detail?.name ?? playlist.name
    }

    /// Rows keyed by song and which of its repeats, not by position: removing row 3 slid
    /// the last row away while every row from 3 down changed title.
    private var keyedRows: [(key: String, index: Int)] {
        var seen: [String: Int] = [:]
        return songs.indices.map { index in
            let id = songs[index].id
            seen[id, default: 0] += 1
            return ("\(id)#\(seen[id]!)", index)
        }
    }
    @State private var selection = SongSelection()
    @State private var isPickingPhoto = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var isReordering = false

    /// Reordering goes through Navidrome's own API — Subsonic has no move at all, only
    /// append and remove-by-index, so the alternative would be emptying the playlist and
    /// re-adding it, which destroys it if the second call fails.
    ///
    /// The list is reordered locally first and re-read afterwards: the server renumbers
    /// positions on every move, so the local copy is only a guess until it confirms.
    private func move(from offsets: IndexSet, to destination: Int) {
        guard let source = offsets.first, var detail else { return }
        // `destination` is an index into the list *before* the row was lifted out, which
        // is exactly what `insert_before` means: the song it lands in front of. The store
        // goes by the songs, not these positions, which a move still on its way changes.
        let shown = songs
        guard shown.indices.contains(source) else { return }
        let song = shown[source]
        let anchor = shown.indices.contains(destination) ? shown[destination] : nil

        detail.entry?.move(fromOffsets: offsets, toOffset: destination)
        self.detail = detail

        Task {
            await store.move(song, shownAt: source, before: anchor, shownAt: destination, in: playlist.id)
            await load()
        }
    }

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            // Playlist order is the server's order; never re-sorted.
            //
            // The indices, not `Array(songs.enumerated())`: the same identities, without
            // copying every song into a new array on each redraw, which for a smart
            // playlist of the whole library is 28,000 of them.
            ForEach(keyedRows, id: \.key) { row in
                let index = row.index
                let song = songs[index]
                // Trailing swipe removes from the playlist here, rather than the generic
                // "add to queue": in a playlist, removal is the action you actually want.
                PlayableSongRow(
                    songs: songs, index: index, source: name, selection: selection,
                    onRemove: {
                        // Gone from the screen at once; the server's answer then decides.
                        if var shown = detail, shown.entry?.indices.contains(index) == true {
                            shown.entry?.remove(at: index)
                            detail = shown
                        }
                        Task {
                            _ = await store.remove(song, shownAt: index, from: playlist.id)
                            await load()
                        }
                    }
                )
            }
            .onMove { offsets, destination in
                move(from: offsets, to: destination)
            }
        }
        .listStyle(.plain)
        .playerClearance()
        .environment(\.editMode, .constant(isReordering ? .active : .inactive))
        .collapsingTitle(name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isReordering {
                    Button("Done") { isReordering = false }
                } else {
                    CollectionDownloadButton(
                        songs: songs, groupID: playlist.id, groupName: name
                    )
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    QueueInsertItems(songs: songs)
                    Divider()
                    Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") {
                        startRadio()
                    }
                    Button("Select Tracks", systemImage: "checkmark.circle") {
                        selection.begin()
                    }
                    Button("Reorder", systemImage: "arrow.up.arrow.down") {
                        isReordering = true
                    }
                    Divider()
                    Button("Choose Photo…", systemImage: "photo") {
                        isPickingPhoto = true
                    }
                    if artwork.hasCustomImage(for: playlist.id) {
                        Button(
                            "Remove Photo",
                            systemImage: "photo.badge.exclamationmark",
                            role: .destructive
                        ) {
                            artwork.removeImage(for: playlist.id)
                        }
                    }
                    if let match = store.playlists.first(where: { $0.id == playlist.id }) {
                        Divider()
                        Button("Rename…", systemImage: "pencil") { editing = match }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $editing, onDismiss: { Task { await load() } }) { EditPlaylistSheet(playlist: $0) }
        // Changed from elsewhere: a song added from the player, which is laid over this
        // screen, so it never comes back into view to load again.
        .onChange(of: store.playlists.first(where: { $0.id == playlist.id }).map { "\($0.songCount ?? 0)\($0.changed ?? "")" }) {
            Task { await load() }
        }
        .safeAreaInset(edge: .bottom) {
            if selection.isActive {
                SelectionToolbar(selection: selection, all: songs, source: name)
            }
        }
        .toolbar {
            if selection.isActive {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { selection.end() }
                }
            }
        }
        // `PhotosPicker` runs out of process and hands back only what was chosen, so it
        // needs no photo-library permission, no usage description and no entitlement --
        // which is why a custom cover is possible on a free account at all.
        .photosPicker(
            isPresented: $isPickingPhoto,
            selection: $pickedItem,
            matching: .images,
            photoLibrary: .shared()
        )
        .task(id: pickedItem) {
            guard let pickedItem,
                  let data = try? await pickedItem.loadTransferable(type: Data.self)
            else { return }
            artwork.setImage(data: data, for: playlist.id)
            self.pickedItem = nil
        }
        .task { await load() }
    }

    private var header: some View {
        VStack(spacing: Metrics.headerToContent) {
            ArtworkImage(
                id: detail?.coverArt ?? playlist.coverArt,
                size: .full,
                cornerRadius: Metrics.radiusHeader,
                playlistID: playlist.id,
                fallbackText: name
            )
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: Metrics.detailArtwork)
            .shadow(radius: 12, y: 6)

            VStack(spacing: 4) {
                Text(name)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                if let comment = detail?.comment, !comment.isEmpty {
                    Text(comment)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            PlayShuffleButtons(
                onPlay: {
                    appState.player.play(songs: playable, startingAt: 0, source: name)
                },
                onShuffle: {
                    appState.player.play(
                        songs: playable, startingAt: 0, source: name, shuffled: true
                    )
                }
            )
            .padding(.horizontal, Metrics.gutter)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.gutter)
    }

    @State private var editing: Playlist?

    private var songs: [Song] { detail?.songs ?? [] }
    /// Shown from the saved copy because the server didn't answer.
    @State private var isSaved = false
    /// What Play and Shuffle start: without the server, the songs on this phone.
    private var playable: [Song] { isSaved ? appState.playableHere(songs) : songs }

    /// Seeded from a random track in the playlist, so the mix differs each time rather
    /// than always radiating out from track one.
    private func startRadio() {
        guard let seed = songs.randomElement() else { return }
        Task {
            let mix = await appState.radio.mix(seed: seed, scope: scope.scope)
            appState.startRadio(
                named: "\(name) Radio", songs: mix,
                station: .radio(seedIDs: songs.map(\.id), title: "\(name) Radio")
            )
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let count = detail?.songCount { parts.append("\(count) songs") }
        if let duration = detail?.duration { parts.append(duration.asLongDuration) }
        return parts.joined(separator: " · ")
    }

    /// The last known state at once, from disk; then the server's, if it answers.
    private func load() async {
        let id = playlist.id
        if detail == nil, let saved = await appState.savedPlaylist(id) {
            detail = saved
            isSaved = true
        }
        let (fresh, saved) = await appState.playlist(id)
        if let fresh {
            detail = fresh
            isSaved = saved
        }
    }
}
