import SwiftUI

/// Describe a mood; Hermes builds the playlist.
///
/// The agent does the whole job on the server — queries the library, picks the tracks,
/// creates the playlist — so what comes back is a real Navidrome playlist that the desktop
/// client sees too, not a local list.
///
/// The name is decided **here** and dictated to the agent, because it is the fallback: if
/// the results file never arrives, a playlist appearing under exactly that name is how the
/// app knows the job worked. That only works if the app chose it, and only stays
/// unambiguous if it does not collide with one that already exists.
struct VibePlaylistView: View {
    @Environment(AppState.self) private var appState

    @State private var vibe = ""
    @State private var trackCount = 25
    /// On: nothing downloads, as playlist sync is now chosen per playlist. Off: the new
    /// one is kept offline once Hermes has made it.
    @State private var keepServerSideOnly = true
    @State private var isSending = false

    private var store: PlaylistStore { appState.playlistStore }

    private var proposedName: String { VibeTitle.sanitised(vibe) }

    private var nameIsTaken: Bool {
        store.playlists.contains {
            $0.name.compare(proposedName, options: .caseInsensitive) == .orderedSame
        }
    }

    var body: some View {
        List {
            Section {
                TextField("late night drive, rainy sunday, gym", text: $vibe, axis: .vertical)
                    .lineLimit(1...4)

                Stepper("\(trackCount) tracks", value: $trackCount, in: 10...50, step: 5)

                if !vibe.isEmpty {
                    LabeledContent("Will be called", value: proposedName)
                        .font(.footnote)
                    if nameIsTaken {
                        Text("You already have a playlist with that name — a short suffix will be added so this one can be told apart.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("The vibe")
            } footer: {
                Text("Hermes searches the whole library — genre, year, length, whether you've ever played it — and creates the playlist on the server. It usually takes a few minutes.")
            }

            Section {
                Toggle("Keep this one server-side only", isOn: $keepServerSideOnly)
                    .disabled(!appState.playlistSync.isEnabled)
            } footer: {
                // Honest about the consequence: playlist sync is on by default, and a
                // FLAC playlist is not a small download.
                Text(syncFooter)
            }

            Section {
                Button {
                    Task { await send() }
                } label: {
                    if isSending {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Sending…")
                        }
                    } else {
                        Label("Ask Hermes", systemImage: "sparkles")
                    }
                }
                .disabled(vibe.trimmingCharacters(in: .whitespaces).isEmpty || isSending || !appState.hermes.isAvailable)

                if !appState.hermes.isAvailable {
                    Text("Set the Hermes results address in Settings first.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let error = appState.hermes.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            if !appState.hermes.vibes.isEmpty {
                Section("Asked for") {
                    ForEach(appState.hermes.vibes) { pending in
                        VibeRow(pending: pending)
                    }
                }
            }
        }
        .navigationTitle("Make a Playlist")
        .playerClearance()
        .task {
            await store.loadIfNeeded()
            await appState.hermes.refreshVibes(playlists: store.playlists)
        }
        .refreshable {
            await store.load()
            await appState.hermes.refreshVibes(playlists: store.playlists)
        }
    }

    private var syncFooter: String {
        let seconds = trackCount * 240
        let bytes = Int64(Double(seconds) * appState.downloads.catalog.measuredBytesPerSecond)
        return appState.playlistSync.isEnabled
            ? "Switched off, the new \(trackCount)-track playlist is kept offline once it's made: about \(bytes.asFileSize)."
            : "Keep Playlists Offline is off, so nothing is downloaded either way."
    }

    private func send() async {
        isSending = true
        defer { isSending = false }

        let description = vibe.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = VibeTitle.unique(
            proposedName,
            existing: store.playlists.map(\.name),
            requestID: UUID()
        )

        let sent = await appState.hermes.startVibe(
            name: name,
            vibe: description,
            trackCount: trackCount,
            keepsOffline: !keepServerSideOnly && appState.playlistSync.isEnabled
        )
        if sent { vibe = "" }
    }
}

private struct VibeRow: View {
    @Environment(AppState.self) private var appState

    let pending: HermesAsk.PendingVibe

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(pending.name)
                    .font(.body.weight(.medium))
                Spacer()
                status
            }

            Text(pending.vibe)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let note = pending.note, !note.isEmpty {
                Text(note)
                    .font(.footnote.italic())
                    .foregroundStyle(.secondary)
            }

            if let failure = pending.failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if let id = pending.playlistID {
                NavigationLink(value: Destination.playlist(PlaylistRef(id: id, name: pending.name))) {
                    Label("Open playlist", systemImage: "music.note.list")
                        .font(.footnote)
                }
            }
        }
        .swipeActions {
            Button(role: .destructive) {
                appState.hermes.dismissVibe(pending.id)
            } label: {
                Label("Dismiss", systemImage: "xmark")
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if pending.isWaiting {
            ProgressView()
                .controlSize(.small)
        } else if pending.failure != nil {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.appTint)
        }
    }
}
