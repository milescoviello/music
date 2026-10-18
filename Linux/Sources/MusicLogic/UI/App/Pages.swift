import Foundation

/// Every page the app can open, by destination: the phone's `musicDestinations()`.
@MainActor
enum Pages {
    /// The first page of each sidebar section.
    static func root(_ section: Shell.Section, env: Env) -> NavigationPage {
        switch section {
        case .home: return pending("Home", env: env)
        case .library: return LibraryHub.make(env)
        case .search: return pending("Search", env: env)
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
        default:
            return pending(String(describing: destination), env: env)
        }
    }

    private static func pending(_ title: String, env: Env) -> NavigationPage {
        Page.make(title, content: StatusPage(icon: "content-loading-symbolic", title: title))
    }
}
