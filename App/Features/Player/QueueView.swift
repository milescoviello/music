import SwiftUI

/// The play queue, Plexamp's way: what is coming up, and — one tab over — what already
/// played, so a track you half-heard is a tap away rather than gone.
struct QueueView: View {
    @Environment(AppState.self) private var appState
    @Environment(AutoplayService.self) private var autoplay
    @Environment(GuestDJService.self) private var guestDJ

    @State private var tab: Tab = .upNext
    @State private var isSavingAsPlaylist = false
    @State private var isConfirmingClear = false

    private enum Tab: String, CaseIterable {
        case earlier = "Earlier"
        case upNext = "Up Next"
    }

    private var player: PlaybackController { appState.player }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.bottom, 8)

            switch tab {
            case .upNext: upNextList
            case .earlier: earlierList
            }
        }
        .sheet(isPresented: $isSavingAsPlaylist) {
            NewPlaylistSheet(
                songs: player.queue.order.compactMap { index in
                    player.queue.tracks.indices.contains(index)
                        ? player.queue.tracks[index]
                        : nil
                },
                suggestedName: player.queue.sourceDescription
            )
        }
        .confirmationDialog(
            "Clear Play Queue?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear Play Queue", role: .destructive) { player.clearQueue() }
        } message: {
            Text("The track playing keeps playing.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Queue", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)

            Spacer(minLength: 0)

            Menu {
                // A queue built by hand is the one thing in the app that exists
                // nowhere else, so it gets a way out to something permanent.
                Button("Save Play Queue as Playlist…", systemImage: "text.badge.plus") {
                    isSavingAsPlaylist = true
                }
                .disabled(player.queue.tracks.isEmpty)

                Button("Clear Play Queue", systemImage: "trash", role: .destructive) {
                    isConfirmingClear = true
                }
                .disabled(!player.queue.hasUpNext && player.queue.position == 0)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: Metrics.minimumTouchTarget, height: Metrics.minimumTouchTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Queue options")
        }
    }

    private var upNextList: some View {
        List {
            if !player.queue.sourceDescription.isEmpty, player.queue.hasUpNext {
                Text("Playing from \(player.queue.sourceDescription)")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .listRowBackground(Color.clear)
                    .moveDisabled(true)
            }

            ForEach(upNextWithIndices, id: \.orderIndex) { entry in
                row(entry)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            player.removeFromQueue(orderIndex: entry.orderIndex)
                        } label: {
                            Label("Remove", systemImage: "minus.circle")
                        }
                    }
            }
            // Reordering is local, so it is free here -- unlike a server playlist,
            // where the API has no move operation at all.
            .onMove { source, destination in
                guard let from = source.first else { return }
                let start = player.queue.position + 1
                player.moveInQueue(
                    from: start + from,
                    to: start + destination
                )
            }

            if autoplay.isActive, !autoplay.options.isEmpty {
                AutoplayCarousel()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .moveDisabled(true)
                    .deleteDisabled(true)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Always active: a queue is exactly the place where dragging to reorder is
        // expected without first tapping an Edit button.
        .environment(\.editMode, .constant(.active))
        .overlay {
            if !player.queue.hasUpNext, !(autoplay.isActive && !autoplay.options.isEmpty) {
                placeholder("Nothing queued")
            }
        }
    }

    private var earlierList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(earlierWithIndices, id: \.orderIndex) { entry in
                    row(entry)
                        .id(entry.orderIndex)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Oldest first, like the queue itself, but opened at the most recent end:
            // the track that just finished is the one most likely wanted back.
            .onAppear {
                if let last = earlierWithIndices.last { proxy.scrollTo(last.orderIndex, anchor: .bottom) }
            }
            .overlay {
                // The same test `earlier` makes, without building every track already
                // played just to see whether there are any.
                if player.queue.position == 0 || player.queue.position > player.queue.order.count {
                    placeholder("Earlier tracks in the play queue\nwill show up here")
                }
            }
        }
    }

    private func row(_ entry: (orderIndex: Int, song: Song)) -> some View {
        Button {
            player.jump(toOrderIndex: entry.orderIndex)
        } label: {
            HStack(spacing: 6) {
                SongRow(song: entry.song, style: .withArtwork)
                if guestDJ.isPick(entry.song) {
                    // Plexamp marks the DJ's picks, so you can tell its taste from yours.
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(Color.appTint)
                        .accessibilityLabel("Picked by \(guestDJ.dj?.name ?? "the DJ")")
                }
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .contextMenu {
            SongMenu(song: entry.song, showsNavigation: false)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white.opacity(0.6))
    }

    /// The order index is what the controller acts on, so carry it alongside.
    private var upNextWithIndices: [(orderIndex: Int, song: Song)] {
        let queue = player.queue
        let start = queue.position + 1
        guard start < queue.order.count else { return [] }

        // The next few hundred: a 28,000-track queue as a list is a lag spike every time
        // it is drawn, and nobody scrolls that far.
        return (start..<min(queue.order.count, start + 300)).map { index in
            (orderIndex: index, song: queue.tracks[queue.order[index]])
        }
    }

    private var earlierWithIndices: [(orderIndex: Int, song: Song)] {
        let queue = player.queue
        guard queue.position > 0, queue.position <= queue.order.count else { return [] }
        // The last few hundred, like Up Next: deep into a 28,000-track queue this was every
        // track already played, built and handed to the list on each redraw.
        return (max(0, queue.position - 300)..<queue.position).map { index in
            (orderIndex: index, song: queue.tracks[queue.order[index]])
        }
    }
}

/// Plexamp's Autoplay carousel: what plays when the queue runs out, each choice shown as
/// what it actually is — the album, the radio — so picking one is not a guess.
private struct AutoplayCarousel: View {
    @Environment(AutoplayService.self) private var autoplay

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "infinity")
                Text("Autoplay")
                if autoplay.isAdding {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 24)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(autoplay.options) { option in
                        card(option)
                    }
                }
                .padding(.horizontal, 24)
            }
        }
        .padding(.vertical, 12)
    }

    private func card(_ option: AutoplayService.Option) -> some View {
        let isSelected = autoplay.selected == option.choice

        return Button {
            autoplay.select(option.choice)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08))
                    if let cover = option.coverArt {
                        ArtworkImage(id: cover, size: .thumb, cornerRadius: 8)
                    } else {
                        Image(systemName: option.choice.symbol)
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(width: 96, height: 96)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? Color.appTint : .clear, lineWidth: 2)
                }

                Text(option.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(option.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .frame(width: 96, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
