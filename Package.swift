// swift-tools-version: 6.0
import PackageDescription

// Tests only. The app is built by Music.xcodeproj; this package exists so the pure
// logic can be tested with `swift test` on a plain macOS runner -- no simulator, no
// second Xcode target, and no risk of a bad project-file edit breaking the app build.
//
// It compiles the *same* files the app compiles, listed explicitly rather than by
// directory: every file here must be Foundation-only, and naming them keeps a future
// UIKit import from silently breaking the test job.
let package = Package(
    name: "MusicLogic",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "MusicLogic",
            path: "App/Core",
            sources: [
                "Models.swift",
                "Paths.swift",
                "PlaybackQueue.swift",
                "PlayTracker.swift",
                "DownloadCatalog.swift",
                "DownloadFolders.swift",
                "HermesResults.swift",
                "MixEngine.swift",
                "TripPlanner.swift",
                "DSP.swift",
                "StreamCacheIndex.swift",
                "StreamingPolicy.swift",
                "TrackShape.swift",
                "SeekbarLevels.swift",
                "Autoplay.swift",
                "GuestDJ.swift",
                "Stations.swift",
                "LibraryFacets.swift",
                "Charts.swift",
                "HomeLayout.swift",
                "SearchRanking.swift",
                "RecentPlays.swift",
                "SonicClient.swift",
                "BeatMatch.swift",
                "RhythmStore.swift",
            ]
        ),
        .testTarget(
            name: "MusicLogicTests",
            dependencies: ["MusicLogic"],
            path: "Tests/MusicLogicTests"
        ),
    ]
)
