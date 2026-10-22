/// Everything that can be opened as a page: the phone's `Destination`, case for case, so
/// the Core's `Navigator` and the screens agree on what a route is.
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
    /// A downloaded album or playlist, by `DownloadFolders.Folder.id`.
    case downloadFolder(String)
    case settings
    case audioSettings
    case equalizer
    case streamingSettings
    case experienceSettings
    case sonicSettings
    case requestMusic(String)
    case requestSettings
    case offlineSettings
    case remoteControl
    case diagnostics
    case stats
    /// By id: the mix itself lives in `DailyMixes`, which is rebuilt daily.
    case dailyMix(String)
    case rediscover
    /// The first year of the decade: 1990 means 1990-1999.
    case decade(Int)
    case tripMode
    case lyricSearch(String)
    case vibePlaylist
    case libraryHealth
    case dailyMixes
    case stations
    case mixBuilder(MixBuilderKind)
    case sonicAdventure(Song)
    case libraryFacet(LibraryFacet)
    case albumCollection(title: String, albums: [Album])
    case charts
    case tracks
    /// Nil for the top level.
    case folder(FolderRef?)
}

/// Plexamp's library categories that Navidrome has no list for, cut from `LibraryIndex`.
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

    var icon: String {
        switch self {
        case .compilations: return "view-dual-symbolic"
        case .soundtracks: return "camera-video-symbolic"
        case .live: return "audio-input-microphone-symbolic"
        case .singles: return "media-optical-symbolic"
        case .labels: return "music-tag-symbolic"
        case .moods: return "face-smile-symbolic"
        }
    }
}

struct FolderRef: Hashable, Sendable {
    let id: String
    let name: String
}

enum MixBuilderKind: String, Hashable, Sendable {
    case artists
    case albums
}
