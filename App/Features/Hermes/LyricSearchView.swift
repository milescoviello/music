import SwiftUI

/// Searching the library by a line of lyric.
///
/// The app cannot do this itself: Subsonic serves lyrics one track at a time, so finding a
/// phrase would mean 25,784 requests. Hermes runs it as a single query against Navidrome's
/// own database, where the lyrics actually live.
///
/// **Only about 1,690 tracks (6.5%) have lyrics at all**, which the screen says out loud —
/// otherwise a miss reads as "you don't own this song" when it means "there is no lyric on
/// file for it".
struct LyricSearchView: View {
    @Environment(AppState.self) private var appState

    var initialQuery: String = ""

    @State private var query = ""
    @State private var state: SearchState = .idle
    @State private var matches: [LyricMatch] = []
    @State private var songs: [String: Song] = [:]

    private enum SearchState: Equatable {
        case idle
        case asking
        case done
        case failed(String)
    }

    var body: some View {
        List {
            Section {
                TextField("A line you remember", text: $query, axis: .vertical)
                    .lineLimit(1...3)
                    .submitLabel(.search)
                    .onSubmit { Task { await search() } }

                Button {
                    Task { await search() }
                } label: {
                    if state == .asking {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Searching the library…")
                        }
                    } else {
                        Label("Search Lyrics", systemImage: "text.magnifyingglass")
                    }
                }
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || state == .asking)
            } footer: {
                Text("Searches the lyrics stored with your own files. About 6.5% of this library has lyrics, so a miss means there is nothing on file — not that you don't own the song.")
            }

            if case let .failed(message) = state {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            if state == .done {
                if matches.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Lyrics Matched",
                            systemImage: "quote.closing",
                            description: Text("Nothing on file contains that line.")
                        )
                    }
                } else {
                    Section("\(matches.count) matched") {
                        ForEach(matches) { match in
                            row(for: match)
                        }
                    }
                }
            }
        }
        .navigationTitle("Lyric Search")
        .playerClearance()
        .task {
            guard query.isEmpty, !initialQuery.isEmpty else { return }
            query = initialQuery
        }
    }

    @ViewBuilder
    private func row(for match: LyricMatch) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let song = songs[match.songID], let index = playableIndex(of: match) {
                // A real row, so tap-to-play, swipe-to-queue, star and download all come
                // free rather than being reimplemented here.
                PlayableSongRow(songs: playableSongs, index: index, source: "Lyric Search")
                    .id(song.id)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(match.title ?? "Unknown Track")
                    Text([match.artist, match.album].compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let line = match.line {
                Text("“\(line)”")
                    .font(.footnote.italic())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let at = match.atMs, let index = playableIndex(of: match) {
                Button {
                    appState.player.play(
                        songs: playableSongs,
                        startingAt: index,
                        source: "Lyric Search",
                        startAt: Double(at) / 1_000
                    )
                } label: {
                    Label("Play from \((at / 1_000).asDuration)", systemImage: "play.circle")
                        .font(.footnote)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    /// Only the matches that resolved, in match order, so the queue built from a tap is
    /// the list on screen.
    private var playableSongs: [Song] {
        matches.compactMap { songs[$0.songID] }
    }

    private func playableIndex(of match: LyricMatch) -> Int? {
        playableSongs.firstIndex { $0.id == match.songID }
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        state = .asking
        matches = []
        songs = [:]

        // The sonic service first: the same lyrics from the same database, answered in
        // milliseconds, where Hermes has to start an agent run to make one query. Hermes
        // stays for when the service is not there.
        if let hits = await appState.sonic.lyricHits(for: trimmed) {
            let found = hits.map {
                LyricMatch(songID: $0.id, title: $0.title, artist: $0.artist, line: $0.line, atMs: $0.at)
            }
            matches = found
            state = .done
            await resolve(found)
            return
        }

        let outcome = await appState.hermes.ask(
            route: "music-lyrics",
            fields: ["query": trimmed],
            as: LyricSearchResult.self,
            // One SQL query on the other end; the wait is agent startup, not searching.
            timeout: 120
        )

        switch outcome {
        case let .ok(result):
            matches = result.found
            state = .done
            await resolve(result.found)
        case let .failed(message):
            state = .failed(message)
        case .pending:
            state = .failed("Hermes didn't answer in time.")
        }
    }

    /// Turns match ids into real songs with `getSong.view` — the one endpoint the app had
    /// never needed until a feature handed it a bare id.
    private func resolve(_ matches: [LyricMatch]) async {
        await withTaskGroup(of: (String, Song?).self) { group in
            for match in matches.prefix(25) {
                group.addTask { [client = appState.client] in
                    (match.songID, try? await client.song(id: match.songID))
                }
            }
            for await (id, song) in group {
                if let song { songs[id] = song }
            }
        }
    }
}
