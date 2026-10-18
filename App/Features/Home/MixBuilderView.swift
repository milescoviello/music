import SwiftUI

enum MixBuilderKind: String, Hashable, Sendable {
    case artists
    case albums
}

/// Plexamp's Artist and Album Mix Builders: search, pick a few, play a station of them.
///
/// The result is a station, not a fixed list: it keeps going with what is like them once
/// their own tracks have played.
struct MixBuilderView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope
    @Environment(StationService.self) private var stations

    let kind: MixBuilderKind

    @State private var query = ""
    @State private var artists: [Artist] = []
    @State private var albums: [Album] = []
    @State private var chosenArtists: [Artist] = []
    @State private var chosenAlbums: [Album] = []
    @State private var suggestions: [Artist] = []

    /// Plexamp caps a builder at a handful; more than this and the mix is just the library.
    private let limit = 8

    var body: some View {
        List {
            if hasChoices {
                Section {
                    chosenList
                    Button {
                        play()
                    } label: {
                        Label("Play Mix", systemImage: "play.fill")
                            .font(.headline)
                    }
                    .disabled(stations.starting != nil)
                } header: {
                    Text("In This Mix")
                }
            }

            if query.isEmpty, kind == .artists, !suggestions.isEmpty {
                Section("Like These") {
                    ForEach(suggestions) { artist in
                        artistRow(artist)
                    }
                }
            }

            Section {
                switch kind {
                case .artists:
                    ForEach(artists) { artist in artistRow(artist) }
                case .albums:
                    ForEach(albums) { album in albumRow(album) }
                }
            }
        }
        .navigationTitle(kind == .artists ? "Artist Mix Builder" : "Album Mix Builder")
        .searchable(text: $query, prompt: kind == .artists ? "Artists" : "Albums")
        .task(id: query) { await search() }
        .playerClearance()
        .overlay {
            if !hasChoices, query.isEmpty {
                ContentUnavailableView(
                    kind == .artists ? "Pick a few artists" : "Pick a few albums",
                    systemImage: kind == .artists ? "person.2.wave.2" : "square.stack.3d.up",
                    description: Text("Search, tap to add, then play the mix.")
                )
            }
        }
    }

    private var hasChoices: Bool {
        kind == .artists ? !chosenArtists.isEmpty : !chosenAlbums.isEmpty
    }

    @ViewBuilder
    private var chosenList: some View {
        switch kind {
        case .artists:
            ForEach(chosenArtists) { artist in
                Text(artist.name)
            }
            .onDelete { chosenArtists.remove(atOffsets: $0); Task { await suggest() } }
        case .albums:
            ForEach(chosenAlbums) { album in
                Text(album.name)
            }
            .onDelete { chosenAlbums.remove(atOffsets: $0) }
        }
    }

    private func artistRow(_ artist: Artist) -> some View {
        let isChosen = chosenArtists.contains { $0.id == artist.id }
        return Button {
            if isChosen {
                chosenArtists.removeAll { $0.id == artist.id }
            } else if chosenArtists.count < limit {
                chosenArtists.append(artist)
            }
            Task { await suggest() }
        } label: {
            HStack {
                ArtworkImage(id: artist.coverArt, size: .thumb, cornerRadius: 20)
                    .frame(width: 40, height: 40)
                Text(artist.name)
                Spacer()
                Image(systemName: isChosen ? "checkmark.circle.fill" : "plus.circle")
                    .foregroundStyle(isChosen ? Color.appTint : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func albumRow(_ album: Album) -> some View {
        let isChosen = chosenAlbums.contains { $0.id == album.id }
        return Button {
            if isChosen {
                chosenAlbums.removeAll { $0.id == album.id }
            } else if chosenAlbums.count < limit {
                chosenAlbums.append(album)
            }
        } label: {
            HStack {
                ArtworkImage(id: album.coverArt, size: .thumb, cornerRadius: 4)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.name).lineLimit(1)
                    if let artist = album.artist {
                        Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: isChosen ? "checkmark.circle.fill" : "plus.circle")
                    .foregroundStyle(isChosen ? Color.appTint : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            artists = []
            albums = []
            return
        }
        // Debounce: `.task(id:)` cancels this when the query changes again.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }

        let result = try? await appState.client.search(
            query: text,
            artistCount: kind == .artists ? 20 : 0,
            albumCount: kind == .albums ? 20 : 0,
            songCount: 0,
            scope: scope.scope
        )
        artists = result?.artists ?? []
        albums = result?.albums ?? []
    }

    /// Plexamp suggests as you build. Here: artists similar to the last one added.
    private func suggest() async {
        guard let last = chosenArtists.last else {
            suggestions = []
            return
        }
        let info = try? await appState.client.artistInfo(id: last.id, similarCount: 8)
        let chosen = Set(chosenArtists.map(\.id))
        suggestions = (info?.similarArtists ?? []).filter { !chosen.contains($0.id) }
    }

    private func play() {
        switch kind {
        case .artists:
            stations.play(.artistMix(ids: chosenArtists.map(\.id), names: chosenArtists.map(\.name)))
        case .albums:
            stations.play(.albumMix(ids: chosenAlbums.map(\.id), names: chosenAlbums.map(\.name)))
        }
    }
}

/// Plexamp's Sonic Adventure: pick where to end up, and the queue finds a way there from
/// the track you started on.
struct SonicAdventureView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope
    @Environment(StationService.self) private var stations
    @Environment(\.dismiss) private var dismiss

    let start: Song

    @State private var query = ""
    @State private var results: [Song] = []
    @State private var building: Song?

    var body: some View {
        List {
            Section {
                SongRow(song: start, style: .withArtwork)
            } header: {
                Text("From")
            } footer: {
                Text("""
                Plexamp walks a map of how tracks sound. Navidrome has no such map, so the \
                way is found through what your server considers related to each end: \
                tracks near the start, then near both, then near the destination.
                """)
            }

            Section("To") {
                ForEach(results) { song in
                    Button {
                        go(to: song)
                    } label: {
                        HStack {
                            SongRow(song: song, style: .withArtwork)
                            if building?.id == song.id { ProgressView() }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(building != nil)
                }
            }
        }
        .navigationTitle("Sonic Adventure")
        .searchable(text: $query, prompt: "Where to?")
        .task(id: query) { await search() }
        .playerClearance()
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            results = []
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let found = try? await appState.client.search(
            query: text, artistCount: 0, albumCount: 0, songCount: 30, scope: scope.scope
        )
        results = (found?.songs ?? []).filter { $0.id != start.id }
    }

    private func go(to end: Song) {
        building = end
        Task {
            await stations.playAdventure(from: start, to: end)
            building = nil
            dismiss()
        }
    }
}
