import Foundation

/// Where everything on disk lives.
///
/// Application Support, not Caches: iOS purges Caches under storage pressure while
/// the app is not running, which would silently delete downloaded music. Not
/// Documents either -- that is included in iCloud backups, and a lossless library
/// has no business in someone's iCloud quota.
enum Paths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Music", isDirectory: true)
    }()

    /// Completed, playable audio. Flat rather than per-album: song ids are unique,
    /// album membership lives in the catalog, and eviction becomes one listing.
    static let media = root.appendingPathComponent("Media", isDirectory: true)
    /// Staged downloads. Never handed to AVPlayer.
    static let incoming = media.appendingPathComponent("incoming", isDirectory: true)
    static let artwork = root.appendingPathComponent("Artwork", isDirectory: true)
    /// One file per pending server mutation.
    static let outbox = root.appendingPathComponent("Outbox", isDirectory: true)
    static let lyrics = root.appendingPathComponent("Lyrics", isDirectory: true)
    /// Last-known library metadata, so the normal screens work offline.
    static let metadata = root.appendingPathComponent("Metadata", isDirectory: true)

    /// Things that can be fetched or measured again: the stream cache, the measured
    /// shapes of tracks, the seekbar levels our sonic service gave, and translated
    /// lyrics. Caches, deliberately — iOS may purge it while the app is not running,
    /// and every store checks for its files rather than trusting an index.
    static let caches: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Music", isDirectory: true)
    }()
    static let streamCache = caches.appendingPathComponent("Streams", isDirectory: true)
    static let trackShapes = caches.appendingPathComponent("Shapes", isDirectory: true)
    static let seekbarLevels = caches.appendingPathComponent("Levels", isDirectory: true)
    /// English translations of lyrics, made on the phone.
    static let lyricTranslations = caches.appendingPathComponent("Translations", isDirectory: true)

    static let catalog = root.appendingPathComponent("catalog.json")
    static let queue = root.appendingPathComponent("queue.json")

    /// Creates every directory and re-marks them backup-excluded.
    ///
    /// Called synchronously at launch before anything else, because the background
    /// download session's delegate can fire before any UI exists. The exclusion flag
    /// is re-applied every launch: it is lost whenever a directory is recreated.
    static func bootstrap() {
        for directory in [root, media, incoming, artwork, outbox, lyrics, metadata, streamCache, trackShapes, seekbarLevels, lyricTranslations] {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            var url = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }

    static func mediaFile(songID: String, suffix: String) -> URL {
        media.appendingPathComponent("\(songID).\(suffix)")
    }

    static func partFile(songID: String, suffix: String) -> URL {
        incoming.appendingPathComponent("\(songID).\(suffix).part")
    }

    static func lyricsFile(songID: String) -> URL {
        lyrics.appendingPathComponent("\(songID).json")
    }

    /// Room for something the user explicitly asked for.
    ///
    /// `volumeAvailableCapacityForImportantUsage`, not the raw free bytes: it is the
    /// figure that accounts for caches iOS will purge on demand, so it is what a download
    /// can actually use rather than what `df` would say.
    static var availableBytes: Int64 {
        #if canImport(Darwin)
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
        #else
        // Linux Foundation has no such key. Only the test package ever builds there, and
        // nothing it tests asks how much room the phone has.
        return 0
        #endif
    }
}
