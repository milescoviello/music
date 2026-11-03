import Foundation

/// Send Logs, on both apps: the report from what the app knows now, and the sonic service
/// as where it goes, since that is the one service on the server the app already talks to
/// that is our own.
extension AppState {
    /// `version` is the build as Settings shows it, which each platform reads its own way.
    func logReport(version: String, note: String) async -> LogReport {
        let queue = player.queue
        var playback: [LogReport.Row] = []
        if let song = player.currentSong {
            let artist = song.artist.map { " — \($0)" } ?? ""
            playback.append(.init(label: "Song", value: "\(song.title)\(artist) (\(song.id))"))
            let state = player.isBuffering ? "Buffering" : player.isPlaying ? "Playing" : "Paused"
            playback.append(.init(label: "State", value: "\(state) at \(LogReport.clock(player.elapsed)) of \(LogReport.clock(player.duration))"))
            let order = queue.isShuffled ? "shuffled" : "in order"
            playback.append(.init(label: "Queue", value: "\(queue.position + 1) of \(queue.order.count), \(order), repeat \(queue.repeatMode.rawValue)"))
            if !queue.sourceDescription.isEmpty {
                playback.append(.init(label: "From", value: queue.sourceDescription))
            }
            if player.speed != 1 {
                playback.append(.init(label: "Speed", value: "\(player.speed)×"))
            }
        } else {
            playback.append(.init(label: "Song", value: "Nothing playing"))
        }
        if let unreachable = player.unreachableSongID {
            playback.append(.init(label: "Couldn't play", value: unreachable))
        }
        if player.remote != nil {
            playback.append(.init(label: "Playing to", value: "Another device"))
        }

        let connection: [LogReport.Row] = [
            .init(label: "Server", value: credentials?.baseURL.host ?? "Not signed in"),
            .init(label: "Network", value: reachability.isOnline ? "Online" : "Offline"),
            .init(label: "Showing cached data", value: isShowingCachedData ? "Yes" : "No"),
            .init(label: "Sonic", value: sonic.status.map { "\($0.analysed) of \($0.tracks) analysed" }
                ?? "Not connected\(sonic.lastError.map { ": \($0)" } ?? "")"),
        ]

        let pending = await outbox.summary()
        var sync: [LogReport.Row] = pending.keys.sorted { $0.rawValue < $1.rawValue }.map {
            .init(label: "Waiting to send (\($0.rawValue))", value: "\(pending[$0] ?? 0)")
        }
        sync.append(.init(label: "Queue uploaded", value: queueSync.lastPushedAt.map(Self.logTime) ?? "Not yet"))
        sync.append(.init(label: "Downloads", value: "\(downloads.catalog.entries.count)"))
        if !downloads.progress.isEmpty {
            sync.append(.init(label: "Downloading", value: "\(downloads.progress.count)"))
        }
        let stalled = downloads.catalog.pending.keys.filter { downloads.progress[$0] == nil }.count
        if stalled > 0 {
            sync.append(.init(label: "Stalled downloads", value: "\(stalled)"))
        }
        sync.append(.init(label: "Daily mixes", value: "\(mixes.mixes.count) built"))

        // The settings that change what playback and caching do, so a report can be
        // read against them.
        let policy = streaming.policy
        let on = { (flag: Bool) in flag ? "on" : "off" }
        let settings: [LogReport.Row] = [
            .init(label: "On Wi-Fi", value: "\(policy.wifiQuality), cache ahead \(policy.wifiCacheAhead)"),
            .init(label: "On cellular", value: "\(policy.cellularQuality), cache ahead \(policy.cellularCacheAhead)"),
            .init(label: "Cache size", value: "\(policy.cacheMegabytes) MB"),
            .init(label: "Prefer downloads", value: "\(policy.preferDownloads)"),
            .init(label: "Sweet Fades", value: "\(on(audio.sweetFades)), beat-matched \(on(audio.beatMatchedFades))"),
            .init(label: "Loudness leveling", value: on(audio.loudnessLeveling)),
            .init(label: "Equalizer", value: audio.equalizer ? "on, \(audio.presetName)" : "off"),
            .init(label: "Autoplay", value: on(autoplay.isEnabled)),
            .init(label: "Made for You", value: scope.mixScope.logName),
            .init(label: "Browsing", value: scope.scope.logName),
        ]

        return LogReport(
            sentAt: .now,
            app: version,
            system: LogReport.currentSystem,
            note: note,
            sections: [
                .init(title: "Playback", rows: playback),
                .init(title: "Connection", rows: connection),
                .init(title: "Sync", rows: sync),
                .init(title: "Settings", rows: settings),
            ],
            log: await Diagnostics.shared.export()
        )
    }

    /// The name the server keeps it under.
    func sendLogs(_ report: LogReport) async throws -> String {
        try await SonicClient(configuration: sonic.configuration).sendLogs(report.text(), source: LogReport.source)
    }

    private static func logTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}
