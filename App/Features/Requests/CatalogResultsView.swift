import SwiftUI

/// Search's Soulseek side: songs and albums from YouTube Music's catalog, each marked when
/// the library has it already, and the rest one tap from being got, lossless.
struct CatalogResultsView: View {
    @Environment(AppState.self) private var appState
    let query: String
    /// Called when something is asked for: the moment the search is worth keeping.
    var onUse: () -> Void = {}

    @State private var results: SonicClient.CatalogResults?
    @State private var searchedFor = ""
    @State private var isSearching = false
    @State private var failed = false
    @State private var adding: AddMusicItem?

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Group {
            if !appState.grab.isAvailable {
                ContentUnavailableView {
                    Label("Soulseek Needs the Server", systemImage: "arrow.down.circle")
                } description: {
                    Text("Getting music goes through the request service on the server. It isn't answering right now.")
                }
            } else if trimmed.isEmpty {
                ContentUnavailableView {
                    Label("Get Music", systemImage: "arrow.down.circle")
                } description: {
                    Text("Songs and albums that aren't in your library yet. Add one, and it comes in lossless from Soulseek.")
                }
            } else if failed, !isSearching {
                ContentUnavailableView {
                    Label("Can’t Search Right Now", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("The search didn't go through. Try again in a moment.")
                }
            } else if let results, results.songs.isEmpty, results.albums.isEmpty, !isSearching, searchedFor == trimmed {
                ContentUnavailableView.search(text: trimmed)
            } else {
                // Always a list, even before the first answer: an empty view here would
                // drop the backdrop, and the search task with it.
                List {
                    if let results, !results.albums.isEmpty {
                        Section("Albums") {
                            ForEach(results.albums) { album in
                                row(title: album.title,
                                    subtitle: [album.artist, album.type, album.year].compactMap { $0 }.joined(separator: " · "),
                                    cover: album.cover, have: album.have) {
                                    adding = .album(artist: album.artist, title: album.title, year: album.year,
                                                    albumID: album.albumId, cover: album.cover)
                                }
                            }
                        }
                    }
                    if let results, !results.songs.isEmpty {
                        Section("Songs") {
                            ForEach(results.songs) { song in
                                row(title: song.title,
                                    subtitle: [song.artist, song.album].compactMap { $0 }.joined(separator: " · "),
                                    cover: song.cover, have: song.have) {
                                    adding = .song(artist: song.artist, title: song.title, album: song.album,
                                                   albumID: song.albumId, seconds: song.seconds,
                                                   videoID: song.videoId, cover: song.cover)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .overlay {
            if isSearching, results == nil, !trimmed.isEmpty { ProgressView() }
        }
        .addMusic($adding)
        .task(id: trimmed) { await search() }
        .task { await appState.grab.refreshAvailability() }
    }

    private func row(title: String, subtitle: String, cover: URL?, have: Bool, add: @escaping () -> Void) -> some View {
        Button {
            guard !have else { return }
            onUse()
            add()
        } label: {
            HStack(spacing: Metrics.itemSpacing) {
                AsyncImage(url: cover) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusThumb, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body).lineLimit(1)
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if have {
                    Label("In Library", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                        .foregroundStyle(Color.appTint)
                        .accessibilityLabel("Get \(title)")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clearRow()
    }

    /// The `.task(id:)` is the debounce: a keystroke cancels the last one mid-sleep.
    private func search() async {
        let text = trimmed
        guard !text.isEmpty, appState.grab.isAvailable else {
            results = nil
            failed = false
            return
        }
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        isSearching = true
        let found = try? await SonicClient(configuration: appState.sonic.configuration).catalogSearch(text)
        guard !Task.isCancelled else { return }
        results = found ?? results
        searchedFor = text
        failed = found == nil
        isSearching = false
    }
}
