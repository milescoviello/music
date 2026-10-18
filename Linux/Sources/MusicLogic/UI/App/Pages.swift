import Foundation

/// Every page the app can open, by destination: the phone's `musicDestinations()`.
@MainActor
enum Pages {
    /// The first page of each sidebar section.
    static func root(_ section: Shell.Section, env: Env) -> NavigationPage {
        switch section {
        case .home: return HomePage.make(env)
        case .library: return LibraryHub.make(env)
        case .search: return SearchPage.make(env)
        case .downloads: return pending("Downloads", env: env)
        case .settings: return pending("Settings", env: env)
        }
    }

    static func make(_ destination: Destination, env: Env) -> NavigationPage {
        switch destination {
        case let .album(ref):
            return AlbumPage.make(env, album: ref)
        case let .albums(sort):
            return AlbumList.make(env, sort: sort)
        case let .decade(start):
            return AlbumList.make(env, decade: start)
        case .artists:
            return ArtistList.make(env)
        case let .artist(ref):
            return ArtistPage.make(env, artist: ref)
        case .playlists:
            return PlaylistList.make(env)
        case let .playlist(ref):
            return PlaylistPage.make(env, playlist: ref)
        case .genres:
            return GenreList.make(env)
        case let .genre(name):
            return GenrePage.make(env, genre: name)
        case .favorites:
            return FavoritesPage.make(env)
        case let .folder(ref):
            return FolderPage.make(env, folder: ref)
        case .tracks:
            return TracksPage.make(env)
        case let .libraryFacet(facet):
            return LibraryFacetPage.make(env, facet: facet)
        case let .albumCollection(title, albums):
            return AlbumCollection.make(env, title: title, albums: albums)
        case .dailyMixes:
            return MixPages.list(env)
        case let .dailyMix(id):
            return MixPages.mix(env, id: id)
        case .stations:
            return MixPages.stations(env)
        case let .mixBuilder(kind):
            return MixBuilder.make(env, kind: kind)
        case let .sonicAdventure(song):
            return SonicAdventure.make(env, start: song)
        case .rediscover:
            return RediscoverPage.make(env)
        case .tripMode:
            return TripModePage.make(env)
        case .stats:
            return StatsPage.make(env)
        case .charts:
            return ChartsPage.make(env)
        default:
            return pending(String(describing: destination), env: env)
        }
    }

    private static func pending(_ title: String, env: Env) -> NavigationPage {
        Page.make(title, content: StatusPage(icon: "content-loading-symbolic", title: title))
    }
}
