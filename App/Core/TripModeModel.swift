import Foundation
import Observation

/// Trip Mode's plan: how long, at what quality, and which albums, mixes and favourites
/// fit. Shared by the iPhone and Linux screens.
@MainActor
@Observable
final class TripModeModel {
    var days = 3
    var hoursPerDay = 3
    /// Not `original`: at the library's own quality a trip of any length does not fit, and
    /// a default that never works is not a default.
    var quality: DownloadQuality = .standard

    private(set) var groups: [TripPlanner.Group] = []
    private(set) var plan = TripPlanner.Plan()
    private(set) var isLoading = false
    private(set) var freeBytes: Int64 = 0

    var targetText: String {
        TripPlanner.targetSeconds(days: days, hoursPerDay: hoursPerDay).asLongDuration
    }

    func load(appState: AppState, scope: LibraryScope) async {
        isLoading = true
        defer { isLoading = false }

        freeBytes = Paths.availableBytes
        var gathered: [TripPlanner.Group] = []

        // Today's mixes first: they are already in memory, and they are the closest thing
        // the app has to "what this person wants to hear right now".
        for mix in appState.mixes.mixes {
            gathered.append(TripPlanner.Group(
                id: "mix-\(mix.id)", name: mix.title, subtitle: mix.subtitle, songs: mix.songs
            ))
        }

        if let starred = try? await appState.client.starred(scope: scope), !starred.songs.isEmpty {
            gathered.append(TripPlanner.Group(
                id: "favourites", name: "Favourites", subtitle: "Starred", songs: starred.songs
            ))
        }

        // Whole albums, because three tracks off a record is a worse thing to find on a
        // plane than the record. One request each, so this is capped rather than paged.
        let albums = (try? await appState.client.albums(type: .frequent, size: 12, scope: scope)) ?? []
        for album in albums {
            guard let detail = try? await appState.client.albumDetail(id: album.id) else { continue }
            gathered.append(TripPlanner.Group(
                id: album.id, name: album.name, subtitle: album.artist, songs: detail.songs
            ))
        }

        groups = gathered
        replan(downloads: appState.downloads)
    }

    func replan(downloads: DownloadCenter) {
        freeBytes = Paths.availableBytes
        plan = TripPlanner.plan(
            groups: groups,
            downloaded: Set(downloads.catalog.entries.keys),
            targetSeconds: TripPlanner.targetSeconds(days: days, hoursPerDay: hoursPerDay),
            quality: quality,
            freeBytes: freeBytes
        )
    }

    func pack(appState: AppState) {
        for group in plan.groups {
            appState.downloads.download(
                group.songs,
                groupID: group.id,
                groupName: group.name,
                quality: quality
            )
        }
        replan(downloads: appState.downloads)
    }
}
