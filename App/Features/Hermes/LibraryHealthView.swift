import SwiftUI

/// What is wrong with the library, from the one place that can actually tell you.
///
/// Neither API can answer any of this. There is no duplicate query, and no cover-art flag
/// on either endpoint — so Hermes runs a single pass over Navidrome's database instead,
/// which is both exact and instant compared with the 52 paged requests an approximation
/// would have cost.
///
/// Strictly diagnostic. Navidrome mounts the music read-only and neither API can delete a
/// file or edit a tag, so this shows what to fix and lets you compare a duplicate pair by
/// ear; the deleting happens on the server, by a person.
struct LibraryHealthView: View {
    @Environment(AppState.self) private var appState

    @State private var report: HealthReport?
    @State private var isAsking = false
    @State private var failure: String?

    var body: some View {
        List {
            Group {
                if let report {
                    summary(report)
                    duplicates(report)
                    gaps(report)
                } else {
                    Section {
                        Button {
                            Task { await ask() }
                        } label: {
                            if isAsking {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text("Asking Hermes…")
                                }
                            } else {
                                Label("Check the library", systemImage: "stethoscope")
                            }
                        }
                        .disabled(isAsking || !appState.hermes.isAvailable)

                        if !appState.hermes.isAvailable {
                            Text("Set the Hermes results address in Settings first.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if let failure {
                            Text(failure)
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    } footer: {
                        Text("One query against Navidrome's own database — duplicates across your two music folders, missing years, missing artwork, and the files that have to be streamed transcoded.")
                    }
                }
            }
            .glassRow()
        }
        .navigationTitle("Library Health")
        .playerClearance()
        .toolbar {
            if let report {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: exportText(report)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .refreshable { await ask() }
    }

    @ViewBuilder
    private func summary(_ report: HealthReport) -> some View {
        Section("Library") {
            if let total = report.totalTracks {
                LabeledContent("Tracks", value: "\(total)")
            }
            LabeledContent(
                "Duplicated across folders",
                value: "\(report.duplicateGroups?.count ?? 0) shown"
            )
            if let missing = report.missingYear {
                LabeledContent("No year", value: "\(missing)")
            }
            if let missing = report.missingArtwork {
                LabeledContent("No cover art", value: "\(missing)")
            }
        }
    }

    @ViewBuilder
    private func duplicates(_ report: HealthReport) -> some View {
        if let groups = report.duplicateGroups, !groups.isEmpty {
            Section {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title)
                            .font(.body.weight(.medium))
                        if let artist = group.artist {
                            Text(artist)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(group.copies) { copy in
                            HStack(alignment: .top, spacing: 8) {
                                // Playing each side is the only way to settle which copy
                                // is the better rip, which is the actual decision here.
                                Button {
                                    Task { await play(copy) }
                                } label: {
                                    Image(systemName: "play.circle")
                                }
                                .buttonStyle(.borderless)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(copy.path ?? copy.songID)
                                        .font(.caption.monospaced())
                                        .lineLimit(2)
                                    Text([
                                        copy.library,
                                        copy.suffix?.uppercased(),
                                        copy.sizeBytes.map { $0.asFileSize },
                                    ].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Same recording, both folders")
            } footer: {
                Text("Navidrome mounts the music read-only, so nothing here can be deleted from the app. Play both and delete the worse one on the server.")
            }
        }
    }

    @ViewBuilder
    private func gaps(_ report: HealthReport) -> some View {
        if let undecodable = report.undecodable, !undecodable.isEmpty {
            Section {
                ForEach(undecodable) { track in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.path ?? track.songID)
                            .font(.caption.monospaced())
                            .lineLimit(2)
                        Text([track.library, track.suffix?.uppercased()]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            } header: {
                Text("Streamed, not downloaded")
            } footer: {
                // Not breakage: the app already handles these, it just cannot seek in
                // them cleanly. Saying that is more useful than flagging them red.
                Text("iOS can't decode these containers, so they play through the server's transcoder. They work — seeking is just less precise.")
            }
        }
    }

    private func ask() async {
        isAsking = true
        failure = nil
        defer { isAsking = false }

        let outcome = await appState.hermes.ask(
            route: "music-health",
            fields: [:],
            as: HealthReport.self,
            timeout: 180
        )

        switch outcome {
        case let .ok(result):
            report = result
        case let .failed(message):
            failure = message
        case .pending:
            failure = "Hermes didn't answer in time."
        }
    }

    private func play(_ copy: HealthReport.HealthTrack) async {
        guard let song = try? await appState.client.song(id: copy.songID) else { return }
        appState.player.play(songs: [song], startingAt: 0, source: "Library Health")
    }

    /// A plain-text report, because the fixing happens on the server and this is the thing
    /// you paste into a shell session there.
    private func exportText(_ report: HealthReport) -> String {
        var lines = ["Music library health"]
        if let total = report.totalTracks { lines.append("Tracks: \(total)") }
        if let missing = report.missingYear { lines.append("No year: \(missing)") }
        if let missing = report.missingArtwork { lines.append("No cover art: \(missing)") }
        lines.append("")

        for group in report.duplicateGroups ?? [] {
            lines.append("\(group.artist ?? "Unknown") — \(group.title)")
            for copy in group.copies {
                lines.append("  \(copy.library ?? "?"): \(copy.path ?? copy.songID)")
            }
        }

        if let undecodable = report.undecodable, !undecodable.isEmpty {
            lines.append("")
            lines.append("Transcoded on playback:")
            for track in undecodable {
                lines.append("  \(track.path ?? track.songID)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
