import SwiftUI

/// Albums held in both libraries, side by side, weakest copy first: format, depth and
/// rate, tracks, plays, size and folder, for deciding by hand which to keep. A copy opens
/// its album. Nothing here moves or deletes anything (`duplicates.py`, on the service).
struct DuplicateAlbumsView: View {
    @Environment(AppState.self) private var appState
    @State private var pairs: [SonicClient.DuplicateAlbum]?
    @State private var failed = false

    var body: some View {
        Group {
            if let pairs {
                if pairs.isEmpty {
                    ContentUnavailableView("No Duplicates", systemImage: "checkmark.circle",
                                           description: Text("No album is in both libraries."))
                } else {
                    list(pairs)
                }
            } else if failed {
                ContentUnavailableView("Couldn't Load", systemImage: "wifi.exclamationmark",
                                       description: Text("The sonic service didn't answer."))
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Duplicate Albums")
        .task {
            do {
                pairs = try await SonicClient(configuration: appState.sonic.configuration).duplicateAlbums()
            } catch {
                failed = true
            }
        }
    }

    private func list(_ pairs: [SonicClient.DuplicateAlbum]) -> some View {
        List {
            Section {
                Text(summary(pairs)).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(pairs) { pair in
                Section {
                    ForEach(Array(pair.copies.enumerated()), id: \.element.id) { index, copy in
                        NavigationLink(value: Destination.album(AlbumRef(id: copy.albumId, name: copy.name, artist: copy.artist))) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text("\(copy.library) · \(copy.format)").font(.subheadline.weight(.medium))
                                    if index == 0 && !pair.alike {
                                        Text("Weaker").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                                    }
                                }
                                Text(details(copy)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                } header: {
                    Text(pair.name)
                } footer: {
                    Text(pair.alike ? "\(pair.artist) · the same in both" : pair.artist)
                }
            }
        }
    }

    private func summary(_ pairs: [SonicClient.DuplicateAlbum]) -> String {
        let alike = pairs.filter(\.alike).count
        let albums = pairs.count == 1 ? "1 album is" : "\(pairs.count) albums are"
        return "\(albums) in both libraries; \(alike) of them the same quality in both. The weaker copy is first."
    }

    private func details(_ copy: SonicClient.DuplicateAlbum.Copy) -> String {
        [
            "\(copy.tracks) \(copy.tracks == 1 ? "track" : "tracks")",
            "\(copy.plays) \(copy.plays == 1 ? "play" : "plays")",
            copy.size.asFileSize,
            copy.folder,
        ].joined(separator: " · ")
    }
}
