import SwiftUI

/// The About section of an album or artist page (`SongAbout` from the companion service, `record_about.py`):
/// Claude's summary, or the first passage of its Genius or Wikipedia page, five lines until "More"; "Sources"
/// opens everything it rests on, quoted, with the pages' links.
struct RecordAboutSection: View {
    let about: SongAbout
    let kind: RecordKind
    /// The album or artist, and for an album its artist: the sheet's header.
    let title: String
    var byline: String?

    @State private var isExpanded = false
    @State private var showsSources = false

    var body: some View {
        if let preview = about.preview(of: kind) {
            VStack(alignment: .leading, spacing: 6) {
                Text(preview.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(isExpanded ? nil : 5)
                HStack(spacing: 16) {
                    Button(isExpanded ? "Less" : "More") {
                        withAnimation { isExpanded.toggle() }
                    }
                    if about.hasSources {
                        Button("Sources") { showsSources = true }
                    }
                }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.borderless)
                Text(preview.credit)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .sheet(isPresented: $showsSources) {
                RecordAboutSheet(about: about, kind: kind, title: title, byline: byline)
            }
        }
    }
}

/// Everything an album's or artist's About rests on: the summary, the passages quoted from its Genius and
/// Wikipedia pages, and their links. As About This Song, without the notes on lines.
struct RecordAboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    let about: SongAbout
    let kind: RecordKind
    let title: String
    var byline: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.title2.weight(.bold))
                        if let byline, !byline.isEmpty {
                            Text(byline)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if kind == .album, let released = about.releasedLine {
                            Text(released)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let summary = about.summary, let preview = about.preview(of: kind) {
                        AboutSummaryCard(heading: kind == .album ? "What it's about" : "Who they are",
                                         text: summary.text, credit: preview.credit)
                    }
                    AboutBackground(sections: about.sections)
                    AboutLinks(links: about.links)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .navigationTitle(kind == .album ? "About This Album" : "About This Artist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Parts shared with About This Song

/// Claude's summary in its card, saying whose words they are and what they rest on.
struct AboutSummaryCard: View {
    let heading: String
    let text: String
    let credit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AboutHeading(title: heading)
            Text(text)
                .font(.body)
            Text(credit)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// The passages quoted from Genius and Wikipedia, each under where it came from.
struct AboutBackground: View {
    let sections: [SongAbout.Section]

    var body: some View {
        if !sections.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                AboutHeading(title: "Background")
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(section.source) · \(section.heading)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(section.text)
                            .font(.callout)
                    }
                }
            }
        }
    }
}

/// The pages themselves: Genius, Wikipedia, and whatever the summary's facts came from.
struct AboutLinks: View {
    let links: [SongAbout.Link]

    var body: some View {
        if !links.isEmpty {
            // In a row while they fit; a summary's own sources can make five, which go one under another.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { buttons }
                VStack(alignment: .leading, spacing: 10) { buttons }
            }
        }
    }

    private var buttons: some View {
        ForEach(links) { link in
            if let address = link.url, let url = URL(string: address) {
                Link(destination: url) {
                    Label(link.name, systemImage: "arrow.up.right.square")
                }
                .font(.subheadline)
            }
        }
    }
}

struct AboutHeading: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
    }
}
