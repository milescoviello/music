import SwiftUI

/// Plexamp's library categories that Navidrome has no list for — compilations,
/// soundtracks, live albums, singles, record labels, moods — cut from `LibraryIndex`.
enum LibraryFacet: String, Hashable, Sendable, CaseIterable {
    case compilations, soundtracks, live, singles, labels, moods

    var title: String {
        switch self {
        case .compilations: return "Compilations"
        case .soundtracks: return "Soundtracks"
        case .live: return "Live"
        case .singles: return "Singles & EPs"
        case .labels: return "Record Labels"
        case .moods: return "Moods"
        }
    }

    var symbol: String {
        switch self {
        case .compilations: return "rectangle.stack"
        case .soundtracks: return "film"
        case .live: return "music.mic.circle"
        case .singles: return "opticaldisc"
        case .labels: return "building.2"
        case .moods: return "face.smiling"
        }
    }
}

struct LibraryFacetView: View {
    @Environment(LibraryIndex.self) private var index
    @Environment(LibraryScopeStore.self) private var scope

    let facet: LibraryFacet

    var body: some View {
        Group {
            switch facet {
            case .labels: GroupList(groups: index.labels, empty: "No record labels tagged")
            case .moods: GroupList(groups: index.moods, empty: "No moods tagged")
            case .compilations: AlbumGrid(albums: index.compilations)
            case .soundtracks: AlbumGrid(albums: index.soundtracks)
            case .live: AlbumGrid(albums: index.live)
            case .singles: AlbumGrid(albums: index.singles)
            }
        }
        .navigationTitle(facet.title)
        .overlay {
            if index.albums.isEmpty, index.isLoading { ProgressView() }
        }
        .task(id: scope.generation) { await index.ensureLoaded(scope: scope.scope) }
    }
}

/// Labels or moods: one row each, with how many albums, opening their albums.
private struct GroupList: View {
    let groups: [LibraryFacets.Group]
    let empty: String

    var body: some View {
        List(groups) { group in
            NavigationLink(value: Destination.albumCollection(title: group.name, albums: group.albums)) {
                LabeledContent(group.name, value: "\(group.albums.count)")
            }
        }
        .playerClearance()
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView(empty, systemImage: "tag", description: Text("Your server reads these from the files' tags."))
            }
        }
    }
}

/// A fixed list of albums in the library's two-column grid.
struct AlbumGrid: View {
    let albums: [Album]

    private let columns = [
        GridItem(.flexible(), spacing: Metrics.itemSpacing),
        GridItem(.flexible(), spacing: Metrics.itemSpacing),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
                    NavigationLink(value: Destination.album(AlbumRef(album))) {
                        AlbumCard(album: album)
                    }
                    .buttonStyle(.plain)
                    .albumMenu(album)
                    .prefetchingCovers(of: albums, after: index)
                }
            }
            .padding(.horizontal, Metrics.gutter)
        }
        .playerClearance()
    }
}

/// A titled album grid, for anything that hands over its albums whole: a label, a mood,
/// a hub's "See All".
struct AlbumCollectionView: View {
    let title: String
    let albums: [Album]

    var body: some View {
        AlbumGrid(albums: albums)
            .navigationTitle(title)
    }
}
