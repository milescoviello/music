import SwiftUI

/// Everything that can be pushed. Registered once per `NavigationStack` via
/// `.musicDestinations()`.
enum Destination: Hashable {
    case album(AlbumRef)
    case artist(ArtistRef)
    case playlist(PlaylistRef)
    case genre(String)
    case albums(AlbumSort)
    case artists
    case playlists
    case genres
    case favorites
    case downloads
    case settings
    case audioSettings
    case equalizer
    case streamingSettings
    case requestMusic(String)
    case requestSettings
    case offlineSettings
    case diagnostics
    case stats
    /// By id rather than by value: the mix itself lives in `DailyMixes`, which is
    /// rebuilt daily, and a route carrying 25 songs would pin a stale copy.
    case dailyMix(String)
    case rediscover
    /// The first year of the decade: 1990 means 1990-1999.
    case decade(Int)
    case tripMode
    case lyricSearch(String)
    case vibePlaylist
    case libraryHealth
    case dailyMixes
}

extension View {
    /// Attach to the root container **inside** each `NavigationStack`, exactly once.
    ///
    /// Placing `navigationDestination` inside a lazy container (a `LazyVGrid` cell or
    /// a `List` row) is the classic bug: the modifier is not registered until that
    /// row materialises, so links from rows that scrolled past silently do nothing.
    func musicDestinations() -> some View {
        navigationDestination(for: Destination.self) { destination in
            switch destination {
            case let .album(ref):
                AlbumDetailView(album: ref)
            case let .artist(ref):
                ArtistDetailView(artist: ref)
            case let .playlist(ref):
                PlaylistDetailView(playlist: ref)
            case let .genre(name):
                GenreDetailView(genre: name)
            case let .albums(sort):
                AlbumListView(initialSort: sort)
            case .artists:
                ArtistListView()
            case .playlists:
                PlaylistListView()
            case .genres:
                GenreListView()
            case .favorites:
                FavoritesView()
            case .downloads:
                DownloadsView()
            case .settings:
                SettingsView()
            case .audioSettings:
                AudioSettingsView()
            case .equalizer:
                EqualizerView()
            case .streamingSettings:
                StreamingSettingsView()
            case let .requestMusic(prefill):
                MusicRequestView(initialText: prefill)
            case .requestSettings:
                MusicRequestSettingsView()
            case .offlineSettings:
                OfflineSettingsView()
            case .diagnostics:
                DiagnosticsView()
            case .stats:
                StatsView()
            case let .dailyMix(id):
                DailyMixView(mixID: id)
            case .rediscover:
                RediscoverView()
            case let .decade(start):
                AlbumListView(decade: start)
            case .tripMode:
                TripModeView()
            case let .lyricSearch(prefill):
                LyricSearchView(initialQuery: prefill)
            case .vibePlaylist:
                VibePlaylistView()
            case .libraryHealth:
                LibraryHealthView()
            case .dailyMixes:
                DailyMixesView()
            }
        }
    }
}
