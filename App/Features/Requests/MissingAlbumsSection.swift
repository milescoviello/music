import SwiftUI

/// An artist's own albums and EPs the library does not have, from MusicBrainz, each one
/// tap from being got. The artist's page loads them (`load`) and shows this only when
/// there are some: never while the request service is away.
struct MissingAlbumsSection: View {
    let artist: ArtistRef
    let missing: [SonicClient.CatalogRecord]

    @State private var showsAll = false
    @State private var adding: AddMusicItem?

    private static let shown = 4

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.headerToContent) {
            Text("Not in Your Library")
                .font(.title3.weight(.semibold))
            VStack(spacing: 0) {
                ForEach(showsAll ? missing : Array(missing.prefix(Self.shown))) { record in
                    Button {
                        adding = .album(artist: artist.name, title: record.title, year: record.year)
                    } label: {
                        HStack(spacing: Metrics.itemSpacing) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.title).font(.body).lineLimit(1)
                                Text([record.type, record.year].compactMap { $0 }.joined(separator: " · "))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "plus.circle")
                                .font(.title3)
                                .foregroundStyle(Color.appTint)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Get \(record.title)")
                }
            }
            if missing.count > Self.shown {
                Button(showsAll ? "Show Less" : "Show All \(missing.count)") {
                    withAnimation(.easeInOut(duration: 0.2)) { showsAll.toggle() }
                }
                .font(.subheadline.weight(.medium))
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .addMusic($adding)
    }

    /// What the library lacks of the artist's records; empty when the service is away.
    @MainActor
    static func load(_ artist: ArtistRef, appState: AppState) async -> [SonicClient.CatalogRecord] {
        await appState.grab.refreshAvailability()
        guard appState.grab.isAvailable, !artist.name.isEmpty else { return [] }
        let client = SonicClient(configuration: appState.sonic.configuration)
        let found = try? await client.catalogArtist(artistID: artist.id, name: artist.name)
        return found?.albums.filter { !$0.have } ?? []
    }
}
