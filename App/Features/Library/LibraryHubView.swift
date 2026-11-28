import SwiftUI

/// The hub. Six peer facets is exactly the case a tab bar cannot hold, which is why
/// Apple Music uses a list here too.
struct LibraryHubView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope
    @Environment(DownloadCenter.self) private var downloads

    @State private var recentlyAdded: [Album] = []

    private let gridColumns = [
        GridItem(.flexible(), spacing: Metrics.itemSpacing),
        GridItem(.flexible(), spacing: Metrics.itemSpacing),
    ]

    /// Driven by `Navigator`, so a jump out of the player can push into this tab.
    private var libraryPath: Binding<NavigationPath> {
        Binding(
            get: { appState.navigator.libraryPath },
            set: { appState.navigator.libraryPath = $0 }
        )
    }

    /// Which rows are pinned to the top, in what order; the rest are under More.
    @AppStorage("library.layout") private var layoutData: Data?
    /// More, once opened, stays open: it is a list gone into often, not a one-off.
    @AppStorage("library.moreShown") private var showsMore = false
    @State private var isEditing = false

    private var layout: LibraryLayout { LibraryLayout.restored(from: layoutData) }

    var body: some View {
        NavigationStack(path: libraryPath) {
            List {
                Group {
                    // Pinned first, in the chosen order. Every way in on one long list -- thirty rows --
                    // was a page of scrolling to the few used every day.
                    Section {
                        ForEach(layout.visible) { item in
                            row(item)
                        }
                    }

                    let more = layout.hiddenInOrder
                    if !more.isEmpty {
                        Section {
                            DisclosureGroup(isExpanded: $showsMore) {
                                ForEach(more) { item in
                                    row(item)
                                }
                            } label: {
                                Label {
                                    Text("More")
                                } icon: {
                                    Image(systemName: "ellipsis.circle")
                                        .foregroundStyle(Color.appTint)
                                        .frame(width: 28, alignment: .center)
                                }
                                .frame(minHeight: Metrics.rowCategory)
                            }
                        }
                    }

                    if !recentlyAdded.isEmpty {
                        Section {
                            // A grid inside a List works reliably as long as the row's
                            // insets and background are cleared.
                            LazyVGrid(columns: gridColumns, spacing: Metrics.itemSpacing) {
                                ForEach(recentlyAdded) { album in
                                    NavigationLink(value: Destination.album(AlbumRef(album))) {
                                        AlbumCard(album: album)
                                    }
                                    .buttonStyle(.plain)
                                    .albumMenu(album)
                                }
                            }
                            .listRowInsets(EdgeInsets(
                                top: 8, leading: Metrics.gutter,
                                bottom: 8, trailing: Metrics.gutter
                            ))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        } header: {
                            HStack {
                                Text("Recently Added")
                                Spacer()
                                NavigationLink(value: Destination.albums(.newest)) {
                                    Text("See All").font(.footnote)
                                }
                            }
                        }
                    }
                }
                .glassRow()
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .navigationTitle("Library")
            .musicDestinations()
            .pageBackdrop()
            .offlineBanner()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { LibraryScopeMenu() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") { isEditing = true }
                }
            }
            .sheet(isPresented: $isEditing) {
                LibraryEditorView(layoutData: $layoutData)
            }
            .task(id: scope.generation) {
                recentlyAdded = (try? await appState.client.albums(
                    type: .newest, size: 6, scope: scope.scope
                )) ?? []
            }
        }
    }

    private func row(_ item: LibraryRow) -> some View {
        // The one row whose contents live on this phone, so it is the one row where a
        // count says something the screen does not.
        let count = downloads.catalog.entries.count
        return row(item.title, item.symbol, item.destination, badge: item == .downloads && count > 0 ? "\(count)" : nil)
    }

    private func row(
        _ title: String,
        _ symbol: String,
        _ destination: Destination,
        badge: String? = nil
    ) -> some View {
        NavigationLink(value: destination) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(Color.appTint)
                    // Fixed icon width so every title shares a left edge.
                    .frame(width: 28, alignment: .center)
            }
        }
        .badge(badge)
        .frame(minHeight: Metrics.rowCategory)
    }
}

/// A row of the Library page, by a name that is kept: the pinned ones and their order are
/// stored by it (`LibraryLayout`).
struct LibraryRow: LayoutItem {
    let rawValue: String
    var id: String { rawValue }

    private init(_ name: String) { rawValue = name }

    init?(rawValue: String) {
        guard Self.allCases.contains(LibraryRow(rawValue)) else { return nil }
        self.rawValue = rawValue
    }

    static let playlists = LibraryRow("playlists")
    static let artists = LibraryRow("artists")
    static let albums = LibraryRow("albums")
    static let tracks = LibraryRow("tracks")
    static let recentlyPlayed = LibraryRow("recentlyPlayed")
    static let mostPlayed = LibraryRow("mostPlayed")
    static let genres = LibraryRow("genres")
    static let stations = LibraryRow("stations")
    static let charts = LibraryRow("charts")
    static let folders = LibraryRow("folders")
    static let favourites = LibraryRow("favourites")
    static let downloads = LibraryRow("downloads")
    static let rediscover = LibraryRow("rediscover")
    static let makePlaylist = LibraryRow("makePlaylist")
    static let lyricSearch = LibraryRow("lyricSearch")
    static let tripMode = LibraryRow("tripMode")
    static let stats = LibraryRow("stats")
    static let libraryHealth = LibraryRow("libraryHealth")
    static let duplicateAlbums = LibraryRow("duplicateAlbums")
    static let requestMusic = LibraryRow("requestMusic")
    static let settings = LibraryRow("settings")

    private static func facet(_ facet: LibraryFacet) -> LibraryRow { LibraryRow("facet.\(facet.rawValue)") }
    private var facet: LibraryFacet? {
        rawValue.hasPrefix("facet.") ? LibraryFacet(rawValue: String(rawValue.dropFirst(6))) : nil
    }

    /// The page's old order, which is the default one.
    static var allCases: [LibraryRow] {
        // No Charts: it is part of Stats now.
        [.playlists, .artists, .albums, .tracks, .recentlyPlayed, .mostPlayed, .genres, .favourites, .downloads,
         .stations]
            + LibraryFacet.allCases.map(facet)
            + [.folders, .rediscover, .makePlaylist, .lyricSearch, .tripMode, .stats, .libraryHealth,
               .duplicateAlbums, .requestMusic, .settings]
    }

    /// Under More until pinned: all but the ways in used every day.
    static var hiddenByDefault: Set<LibraryRow> {
        Set(allCases).subtracting([.playlists, .artists, .albums, .tracks, .recentlyPlayed, .mostPlayed,
                                   .genres, .favourites, .downloads])
    }

    var title: String {
        if let facet { return facet.title }
        switch self {
        case .playlists: return "Playlists"
        case .artists: return "Artists"
        case .albums: return "Albums"
        case .tracks: return "Tracks"
        case .recentlyPlayed: return "Recently Played"
        case .mostPlayed: return "Most Played"
        case .genres: return "Genres"
        case .stations: return "Stations"
        case .charts: return "Charts"
        case .folders: return "Folders"
        case .favourites: return "Favourites"
        case .downloads: return "Downloads"
        case .rediscover: return "Rediscover"
        case .makePlaylist: return "Make a Playlist"
        case .lyricSearch: return "Lyric Search"
        case .tripMode: return "Trip Mode"
        case .stats: return "Stats"
        case .libraryHealth: return "Library Health"
        case .duplicateAlbums: return "Duplicate Albums"
        case .requestMusic: return "Request Music"
        default: return "Settings"
        }
    }

    var symbol: String {
        if let facet { return facet.symbol }
        switch self {
        case .playlists: return "music.note.list"
        case .artists: return "music.microphone"
        case .albums: return "square.stack"
        case .tracks: return "music.note"
        case .recentlyPlayed: return "clock.arrow.circlepath"
        case .mostPlayed: return "chart.bar"
        case .genres: return "guitars"
        case .stations: return "dot.radiowaves.left.and.right"
        case .charts: return "chart.line.uptrend.xyaxis"
        case .folders: return "folder"
        case .favourites: return "heart"
        case .downloads: return "arrow.down.circle"
        case .rediscover: return "clock.arrow.circlepath"
        case .makePlaylist: return "sparkles"
        case .lyricSearch: return "text.magnifyingglass"
        case .tripMode: return "airplane"
        case .stats: return "chart.bar.xaxis"
        case .libraryHealth: return "stethoscope"
        case .duplicateAlbums: return "square.on.square"
        case .requestMusic: return "arrow.down.heart"
        default: return "gearshape"
        }
    }

    var destination: Destination {
        if let facet { return .libraryFacet(facet) }
        switch self {
        case .playlists: return .playlists
        case .artists: return .artists
        case .albums: return .albums(.alphabeticalByName)
        case .tracks: return .tracks
        case .recentlyPlayed: return .albums(.recent)
        case .mostPlayed: return .albums(.frequent)
        case .genres: return .genres
        case .stations: return .stations
        case .charts: return .stats
        case .folders: return .folder(nil)
        case .favourites: return .favorites
        case .downloads: return .downloads
        case .rediscover: return .rediscover
        case .makePlaylist: return .vibePlaylist
        case .lyricSearch: return .lyricSearch("")
        case .tripMode: return .tripMode
        case .stats: return .stats
        case .libraryHealth: return .libraryHealth
        case .duplicateAlbums: return .duplicateAlbums
        case .requestMusic: return .requestMusic("")
        default: return .settings
        }
    }
}

typealias LibraryLayout = ItemLayout<LibraryRow>

/// Apple Music's Library > Edit: which rows are pinned to the top, dragged into order; the
/// rest wait under More.
struct LibraryEditorView: View {
    @Binding var layoutData: Data?
    @Environment(\.dismiss) private var dismiss

    @State private var layout = LibraryLayout.default

    var body: some View {
        NavigationStack {
            List {
                Group {
                    Section {
                        ForEach(layout.order) { item in
                            Toggle(isOn: Binding(
                                get: { layout.isVisible(item) },
                                set: { layout.setVisible($0, item) }
                            )) {
                                Label {
                                    Text(item.title)
                                } icon: {
                                    Image(systemName: item.symbol)
                                        .foregroundStyle(Color.appTint)
                                        .frame(width: 28, alignment: .center)
                                }
                            }
                        }
                        .onMove { layout.move(fromOffsets: $0, toOffset: $1) }
                    } footer: {
                        Text("Pinned rows are at the top, in this order. The rest are under More.")
                    }

                    Section {
                        Button("Reset to Default") { layout = .default }
                            .disabled(layout == .default)
                    }
                }
                .glassRow()
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Edit Library")
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
        .onAppear { layout = LibraryLayout.restored(from: layoutData) }
    }
}
