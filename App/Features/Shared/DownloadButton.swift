import SwiftUI

/// The download control for a whole album or playlist, sitting in the detail
/// header's toolbar.
///
/// One button with three states rather than three controls, and it never asks for
/// confirmation to *start*: downloading is cheap to undo, and a dialog in front of the
/// app's headline feature would be friction for no benefit. Removing does confirm,
/// because that one is destructive.
struct CollectionDownloadButton: View {
    @Environment(DownloadCenter.self) private var downloads

    let songs: [Song]
    let groupID: String
    let groupName: String

    @State private var confirmsRemoval = false

    var body: some View {
        // Once per body: it walks every song in the collection, and the label and the
        // accessibility label each walked it again, on every percent of every download.
        let progress = state

        Button {
            switch state {
            case .none: downloads.download(songs, groupID: groupID, groupName: groupName)
            case .partial: downloads.download(songs, groupID: groupID, groupName: groupName)
            case .working: downloads.remove(songs.map(\.id))
            case .complete: confirmsRemoval = true
            }
        } label: {
            label(progress)
        }
        .buttonStyle(.plain)
        .disabled(songs.isEmpty)
        .confirmationDialog(
            "Remove \(groupName) from this phone?",
            isPresented: $confirmsRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Download", role: .destructive) {
                downloads.remove(songs.map(\.id))
            }
        } message: {
            Text("It stays on your server.")
        }
        .accessibilityLabel(accessibilityLabel(progress))
    }

    @ViewBuilder
    private func label(_ state: Progress) -> some View {
        switch state {
        case .none:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.secondary)
        case let .working(fraction):
            // A determinate ring rather than a spinner: an album is minutes of
            // transfer and "how far along" is the only useful thing to show.
            ProgressView(value: fraction)
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(.appTint)
        case let .partial(done, total):
            Image(systemName: "arrow.down.circle.dotted")
                .foregroundStyle(Color.appTint)
                .accessibilityValue("\(done) of \(total) downloaded")
        case .complete:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Color.appTint)
        }
    }

    /// Not named `State`: a nested type by that name shadows SwiftUI's `@State`
    /// throughout the type, and the resulting errors point everywhere but here.
    private enum Progress {
        case none
        case working(fraction: Double)
        case partial(done: Int, total: Int)
        case complete
    }

    private var state: Progress {
        guard !songs.isEmpty else { return .none }

        var downloaded = 0
        var active: [Double] = []

        for song in songs {
            switch downloads.status(for: song.id) {
            case .downloaded: downloaded += 1
            case .waiting: active.append(0)
            case let .downloading(fraction): active.append(fraction)
            case .none: break
            }
        }

        if !active.isEmpty {
            // Progress across the whole collection, counting the already-finished
            // tracks: otherwise the ring jumps backwards on every track boundary.
            let total = Double(downloaded) + active.reduce(0, +)
            return .working(fraction: total / Double(songs.count))
        }

        if downloaded == songs.count { return .complete }
        if downloaded > 0 { return .partial(done: downloaded, total: songs.count) }
        return .none
    }

    private func accessibilityLabel(_ state: Progress) -> String {
        switch state {
        case .none: return "Download"
        case .working: return "Cancel download"
        case let .partial(done, total): return "Download remaining, \(done) of \(total) done"
        case .complete: return "Remove download"
        }
    }
}

/// The small arrow on a song row that has been downloaded. Deliberately quiet: it is
/// a status, not a control.
struct DownloadedBadge: View {
    @Environment(DownloadCenter.self) private var downloads

    let songID: String

    var body: some View {
        // Not `status(for:)`: that reads the fraction, and this draws the same arrow
        // whatever it is, so every row on screen redrew on every percent for nothing.
        if downloads.isDownloaded(songID) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else if downloads.isArriving(songID) {
            Image(systemName: "arrow.down.circle")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .symbolEffect(.pulse)
        }
    }
}
