import SwiftUI

/// What the song is about, from the player's title or its menu (`SongAbout`): a few sentences written ahead of
/// time, background quoted from the song's Genius and Wikipedia pages, and Genius's notes on its lines, each
/// saying where it came from. The first look at a song takes the server a few seconds; after that it is kept.
struct SongAboutView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let song: Song

    @State private var answer: SonicService.AboutAnswer?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if case .about(let about)? = answer {
                        content(about)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .overlay { placeholder }
            .navigationTitle("About This Song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: song.id) {
            answer = nil
            answer = await appState.sonic.about(song)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(song.title)
                .font(.title2.weight(.bold))
            let byline = [song.artist, song.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if !byline.isEmpty {
                Text(byline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if case .about(let about)? = answer, let facts = about.facts {
                Text(facts)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func content(_ about: SongAbout) -> some View {
        if let summary = about.summary {
            // Whose words these are, and what they rest on.
            AboutSummaryCard(heading: "What it's about", text: summary.text,
                             credit: summary.isReadingOfLyrics
                                ? "Claude's reading of the lyrics: nothing has been written about this song."
                                : "Written by Claude from the sources below.")
        }

        AboutBackground(sections: about.sections)

        if !about.notes.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                AboutHeading(title: "Notes on the lyrics")
                ForEach(about.notes) { note in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.fragment)
                            .font(.callout.italic())
                        Text(note.text)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Capsule().fill(.tertiary).frame(width: 2)
                    }
                }
                Text("From Genius, written mostly by listeners.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }

        AboutLinks(links: about.links)
    }

    @ViewBuilder
    private var placeholder: some View {
        switch answer {
        case nil:
            ProgressView("Looking it up…")
        case .unreachable?:
            ContentUnavailableView("Can't reach the music server", systemImage: "wifi.slash",
                                   description: Text("The song's background comes from it. Try again in a moment."))
        case .unknown?:
            ContentUnavailableView("The server doesn't know this song", systemImage: "questionmark.circle",
                                   description: Text("Songs on the phone alone have no background yet."))
        case .about(let about)? where about.isEmpty:
            if about.unavailable {
                ContentUnavailableView("Couldn't reach Genius or Wikipedia", systemImage: "network.slash",
                                       description: Text("The server tries again within the hour."))
            } else {
                ContentUnavailableView("Nothing written about this song yet", systemImage: "text.magnifyingglass",
                                       description: Text("Neither Genius nor Wikipedia has a page for it."))
            }
        default:
            EmptyView()
        }
    }
}
