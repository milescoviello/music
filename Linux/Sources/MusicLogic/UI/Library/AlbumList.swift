import CGtk
import Foundation

/// Albums as a grid, sorted, a page at a time as it scrolls: the whole library A–Z,
/// recently added or played, a genre's or a decade's. Offline, or with Downloaded Only on,
/// it is what is on this computer instead.
@MainActor
final class AlbumList {
    private let env: Env
    private let genre: String?
    private let decade: Int?
    private var sort: AlbumSort
    private let grid: ItemList<Album, AlbumCardView>
    private let stack = Stack()
    private let status = Bin()
    private var albums: [Album] = []
    private var isLoading = false
    private var canLoadMore = true
    private var generation = 0
    private static let pageSize = 100
    private static let downloadedOnlyKey = "library.downloadedOnly"

    static func make(_ env: Env, sort: AlbumSort = .newest, genre: String? = nil, decade: Int? = nil) -> NavigationPage {
        AlbumList(env, sort: sort, genre: genre, decade: decade).page
    }

    private var page: NavigationPage!

    private init(_ env: Env, sort: AlbumSort, genre: String?, decade: Int?) {
        self.env = env
        self.sort = sort
        self.genre = genre
        self.decade = decade
        grid = Cards.albumGrid(env)
        let scroller = ScrolledWindow(grid.view).vexpand()
        stack.add(scroller, name: "grid")
        stack.add(Spinner().size(32).halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_CENTER), name: "loading")
        stack.add(status, name: "status")

        let title = genre ?? decade.map { "\($0)s" } ?? "Albums"
        let sortButton = MenuButton(icon: "view-sort-descending-symbolic", label: sort.title, "flat") { [weak self] in
            self?.menu() ?? Menu([])
        }
        page = Page.make(title, content: stack, scrolls: false, clamp: nil) { [env] bar in
            if genre == nil, decade == nil {
                bar.end(sortButton)
                bar.end(ScopeMenu.make(env.app))
            }
        }
        page.keep(self)
        let reference = WeakReference(self)
        scroller.onNearEnd { reference.value?.loadMore() }
        stack.observe {
            _ = env.app.scope.generation
            _ = env.app.reachability.isOnline
            _ = UserDefaults.standard.bool(forKey: Self.downloadedOnlyKey)
            Task { @MainActor in reference.value?.reload() }
        }
        stack.observe {
            // The downloaded view follows the catalog as tracks land.
            _ = env.app.downloads.catalog
            guard let list = reference.value, list.isFilteringToDownloads else { return }
            list.showDownloaded()
        }
    }

    private var downloadedOnly: Bool {
        get { UserDefaults.standard.bool(forKey: Self.downloadedOnlyKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.downloadedOnlyKey) }
    }

    /// Forced on when there is no server, because then it is simply the truth.
    private var isFilteringToDownloads: Bool {
        downloadedOnly || !env.app.reachability.isOnline
    }

    private func menu() -> Menu {
        Menu([
            [.choice("Sort", options: AlbumSort.allCases.map { ($0.rawValue, $0.title) }, selected: sort.rawValue) { [weak self] raw in
                guard let self, let chosen = AlbumSort(rawValue: raw) else { return }
                sort = chosen
                reload()
            }],
            [.toggle("Downloaded Only", isOn: downloadedOnly) { [weak self] on in
                self?.downloadedOnly = on
                self?.reload()
            }],
        ])
    }

    private func showDownloaded() {
        var downloaded = env.app.downloads.catalog.downloadedAlbums
        if let genre { downloaded = downloaded.filter { $0.genre?.caseInsensitiveCompare(genre) == .orderedSame } }
        grid.set(downloaded)
        if downloaded.isEmpty {
            status.child = Loader.empty(
                "Nothing Downloaded",
                icon: "folder-download-symbolic",
                description: "Albums you download appear here, and play with no server at all."
            )
            stack.visibleName = "status"
        } else {
            stack.visibleName = "grid"
        }
    }

    private func reload() {
        generation += 1
        albums = []
        canLoadMore = true
        isLoading = false
        if isFilteringToDownloads {
            showDownloaded()
            return
        }
        grid.set([])
        stack.visibleName = "loading"
        loadMore()
    }

    private func loadMore() {
        guard !isLoading, canLoadMore, !isFilteringToDownloads else { return }
        isLoading = true
        let current = generation
        let offset = albums.count
        let app = env.app
        let sort = sort
        let genre = genre
        let decade = decade
        let scope = app.scope.scope
        let reference = WeakReference(self)
        Task { @MainActor in
            var page: [Album]?
            if let decade {
                page = try? await app.client.albums(fromYear: decade, toYear: decade + 9, size: Self.pageSize, offset: offset, scope: scope)
            } else if offset == 0, genre == nil {
                app.beginLoadPass()
                let client = app.client
                page = await app.cached(CacheKey.albumList(sort.rawValue, scope.cacheKey)) {
                    try await client.albums(type: sort, size: 100, offset: 0, scope: scope)
                }
            } else {
                page = try? await app.client.albums(type: sort, size: Self.pageSize, offset: offset, scope: scope, genre: genre)
            }
            // The page may have been closed while this was in flight.
            guard let self = reference.value, current == self.generation else { return }
            self.receive(page)
        }
    }

    private func receive(_ page: [Album]?) {
        isLoading = false
        guard let page else {
            canLoadMore = false
            if albums.isEmpty {
                status.child = Loader.offline()
                stack.visibleName = "status"
            }
            return
        }
        albums += page
        // A short page is the end; random never ends meaningfully, so one page.
        canLoadMore = page.count == Self.pageSize && sort != .random
        grid.set(albums)
        if albums.isEmpty {
            status.child = Loader.empty("No Albums")
            stack.visibleName = "status"
        } else {
            stack.visibleName = "grid"
        }
    }
}
