import SwiftUI

/// Search's YouTube side: music videos, and songs the library does not have. A result
/// plays full screen with a tap; Add to Library gets it, lossless, through the Soulseek
/// pipeline.
struct YouTubeResultsView: View {
    @Environment(VideoService.self) private var videos
    let query: String
    /// Called when a result is watched or added: the moment the search is worth keeping.
    var onUse: () -> Void = {}

    @State private var results: [VideoClient.Video] = []
    @State private var searchedFor = ""
    @State private var isSearching = false
    @State private var failed = false
    @State private var adding: VideoClient.Video?

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Group {
            if !videos.isAvailable {
                ContentUnavailableView {
                    Label("YouTube Needs the Sonic Service", systemImage: "play.rectangle")
                } description: {
                    Text("Videos come through the service on the server. It isn't answering right now.")
                }
            } else if trimmed.isEmpty {
                ContentUnavailableView {
                    Label("Search YouTube", systemImage: "play.rectangle")
                } description: {
                    Text("Music videos, and songs that aren't in your library yet. Play one, or add it to the library.")
                }
            } else if failed, !isSearching {
                ContentUnavailableView {
                    Label("Can’t Reach YouTube", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("The search didn't go through. Try again in a moment.")
                }
            } else if results.isEmpty, !isSearching, searchedFor == trimmed {
                ContentUnavailableView.search(text: trimmed)
            } else {
                List {
                    ForEach(results) { video in
                        row(video)
                    }
                }
                .listStyle(.plain)
            }
        }
        .overlay {
            if isSearching, results.isEmpty, !trimmed.isEmpty { ProgressView() }
        }
        .addToLibrary($adding)
        .task(id: trimmed) { await search() }
    }

    private func row(_ video: VideoClient.Video) -> some View {
        HStack(spacing: 4) {
            Button {
                onUse()
                videos.watch(video)
            } label: {
                VideoRow(video: video)
            }
            .buttonStyle(.plain)

            Button {
                onUse()
                adding = video
            } label: {
                Image(systemName: "plus.circle")
                    .font(.title3)
                    .frame(width: Metrics.minimumTouchTarget, height: Metrics.minimumTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Add \(video.song ?? video.title) to Library")
        }
        .contextMenu {
            Button("Play Video", systemImage: "play.rectangle") {
                onUse()
                videos.watch(video)
            }
            Button("Add to Library…", systemImage: "plus.circle") {
                onUse()
                adding = video
            }
        }
    }

    /// The `.task(id:)` is the debounce: a keystroke cancels the last one mid-sleep.
    private func search() async {
        let text = trimmed
        guard !text.isEmpty, videos.isAvailable else {
            results = []
            failed = false
            return
        }
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        isSearching = true
        let found = await videos.search(text)
        guard !Task.isCancelled else { return }
        results = found ?? []
        searchedFor = text
        failed = found == nil
        isSearching = false
    }
}
