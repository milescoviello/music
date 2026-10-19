// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Two packages in one manifest, chosen by the machine building it.
//
// On macOS this is tests only. The iOS app is built by Music.xcodeproj; this package exists
// so the pure logic can be tested with `swift test` on a plain macOS runner -- no simulator,
// no second Xcode target, and no risk of a bad project-file edit breaking the app build.
// It compiles the *same* files the app compiles, listed explicitly rather than by
// directory: every file here must be Foundation-only, and naming them keeps a future
// UIKit import from silently breaking the test job.
//
// On Linux it is the desktop app. `Linux/Sources/MusicLogic/Core` is a symlink to
// `App/Core`, so the queue, the clients, the stores and the planners are the iPhone's own
// code, unforked; only the files that are Apple frameworks through and through are left
// out, and each has a Linux counterpart under `Linux/Sources/MusicLogic/Platform` with the
// same name and shape. The UI is GTK 4 and libadwaita, the visualisers GL through
// libepoxy, the sound FFmpeg, Rubber Band and PulseAudio (which PipeWire also speaks).
// The module keeps the name `MusicLogic` so the same tests run against it.
//
// `MUSIC_LOGIC_ONLY=1 swift test` on Linux builds the macOS package instead: the logic
// tests alone, on a machine without the GTK, FFmpeg and audio development packages.
//
// Each package is made inside a function, so only the chosen one is ever created: a
// `Package` registers itself as the manifest's result when it is made.

#if os(Linux)
let buildsDesktop = ProcessInfo.processInfo.environment["MUSIC_LOGIC_ONLY"] == nil
#else
let buildsDesktop = false
#endif

/// The Core files that are Apple frameworks through and through. Each is replaced, not
/// patched, by a file of the same name in `Platform/`.
let appleOnly = [
    "AppDelegate.swift",
    "ArtworkStore.swift",
    "AudioSessionCoordinator.swift",
    "AudioTap.swift",
    "Keychain.swift",
    "MusicIntents.swift",
    "Navigator.swift",
    "NowPlayingCenter.swift",
    "PlaylistArtwork.swift",
    "QueuePlayerOutput.swift",
    "Reachability.swift",
    "ScreenAwake.swift",
].map { "Core/\($0)" }

func desktopPackage() -> Package {
    Package(
        name: "Music",
        targets: [
            .systemLibrary(name: "CGtk", path: "Linux/Modules/CGtk", pkgConfig: "gtk4 libadwaita-1"),
            .systemLibrary(
                name: "CFFmpeg",
                path: "Linux/Modules/CFFmpeg",
                pkgConfig: "libavformat libavcodec libswresample libavutil"
            ),
            .systemLibrary(name: "CPulse", path: "Linux/Modules/CPulse", pkgConfig: "libpulse"),
            .systemLibrary(name: "CRubberBand", path: "Linux/Modules/CRubberBand", pkgConfig: "rubberband"),
            .systemLibrary(name: "CEpoxy", path: "Linux/Modules/CEpoxy", pkgConfig: "epoxy"),
            .target(
                name: "MusicLogic",
                dependencies: ["CGtk", "CFFmpeg", "CPulse", "CRubberBand", "CEpoxy"],
                path: "Linux/Sources/MusicLogic",
                exclude: appleOnly
            ),
            .executableTarget(
                name: "music",
                dependencies: ["MusicLogic"],
                path: "Linux/Sources/music"
            ),
            .testTarget(
                name: "MusicLogicTests",
                dependencies: ["MusicLogic"],
                path: "Tests/MusicLogicTests"
            ),
        ]
    )
}

func logicPackage() -> Package {
    Package(
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
                    "VisualizerHost.swift",
                    "VisualizerPalette.swift",
                    "Romanizer.swift",
                    "LyricsLanguage.swift",
                    "LyricTranslationStore.swift",
                ]
            ),
            .testTarget(
                name: "MusicLogicTests",
                dependencies: ["MusicLogic"],
                path: "Tests/MusicLogicTests"
            ),
        ]
    )
}

let package = buildsDesktop ? desktopPackage() : logicPackage()
