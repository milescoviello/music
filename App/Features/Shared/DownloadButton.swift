import SwiftUI

/// The download control for a whole album or playlist, sitting in the detail
/// header's toolbar.
///
/// A toggle, as in Plexamp: one tap downloads it, and while it arrives the button is a
/// ring filling up; once it is all here, a check. Tapping the ring or the check removes
/// this album's or playlist's download — no dialog, because a confirmation in front of
/// the one thing the button does was half of what made it feel broken, and downloading
/// again is one tap.
struct CollectionDownloadButton: View {
    @Environment(DownloadCenter.self) private var downloads
    @Environment(PlaylistSync.self) private var playlistSync

    let songs: [Song]
    let groupID: String
    let groupName: String

    var body: some View {
        // Once per body: it walks every song in the collection.
        let progress = state

        Button {
            switch progress {
            case .none:
                downloads.download(songs, groupID: groupID, groupName: groupName)
            case .working, .complete:
                remove()
            }
        } label: {
            label(progress)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(songs.isEmpty)
        .sensoryFeedback(.selection, trigger: progress.isOn)
        .accessibilityLabel(accessibilityLabel(progress))
    }

    /// This album's or playlist's own download, and the sync that would bring it back.
    /// A collection that is only "all here" because its songs came with other albums or
    /// playlists has nothing of its own; then the button removes what it shows as here,
    /// which is what tapping the check asks for.
    private func remove() {
        playlistSync.stopSyncing(groupID: groupID)
        let own = downloads.catalog.songIDs(downloadedAs: groupID)
        downloads.remove(own.isEmpty ? songs.map(\.id) : own)
    }

    @ViewBuilder
    private func label(_ state: Progress) -> some View {
        switch state {
        case .none:
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
        case let .working(fraction):
            DownloadRing(fraction: fraction)
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.appTint)
        }
    }

    /// Not named `State`: a nested type by that name shadows SwiftUI's `@State`
    /// throughout the type, and the resulting errors point everywhere but here.
    private enum Progress {
        /// Not on the phone, or only some of it with nothing arriving: a tap downloads
        /// whatever is missing.
        case none
        case working(fraction: Double)
        case complete

        var isOn: Bool {
            if case .none = self { return false }
            return true
        }
    }

    private var state: Progress {
        guard !songs.isEmpty else { return .none }

        var downloaded = 0
        var arriving = 0
        var transferred = 0.0

        for song in songs {
            switch downloads.status(for: song.id) {
            case .downloaded: downloaded += 1
            case .waiting: arriving += 1
            case let .downloading(fraction):
                arriving += 1
                transferred += fraction
            case .none: break
            }
        }

        if arriving > 0 {
            // Across the whole collection, counting the tracks already here: otherwise
            // the ring jumps backwards at every track boundary.
            return .working(fraction: (Double(downloaded) + transferred) / Double(songs.count))
        }
        return downloaded == songs.count ? .complete : .none
    }

    private func accessibilityLabel(_ state: Progress) -> String {
        switch state {
        case .none: return "Download"
        case let .working(fraction): return "Downloading, \(Int(fraction * 100)) percent. Remove download"
        case .complete: return "Downloaded. Remove download"
        }
    }
}

/// The App Store's ring: a track filling clockwise, with a stop square in the middle
/// saying that a tap stops it. Drawn rather than a circular `ProgressView`, which on iOS
/// ignores its value and spins.
struct DownloadRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.appTint.opacity(0.25), lineWidth: 2.5)
            Circle()
                // A sliver even at nothing, so a download that is only queued still reads
                // as started.
                .trim(from: 0, to: max(0.03, min(fraction, 1)))
                .stroke(Color.appTint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: fraction)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.appTint)
                .frame(width: 7, height: 7)
        }
        .padding(2)
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
