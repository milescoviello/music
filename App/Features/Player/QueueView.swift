import SwiftUI

/// The play queue, Plexamp's way: what is coming up, and — one tab over — what already
/// played, so a track you half-heard is a tap away rather than gone.
struct QueueView: View {
    @Environment(AppState.self) private var appState
    @Environment(AutoplayService.self) private var autoplay
    @Environment(GuestDJService.self) private var guestDJ
    @Environment(UserStateStore.self) private var userState

    @State private var tab: Tab = .upNext
    @State private var isSavingAsPlaylist = false
    @State private var isConfirmingClear = false
    /// Drag handles showing. Off by default, because a list in edit mode cannot swipe --
    /// iOS turns swipe actions off while one is editing -- and swiping a song away is
    /// what the queue is for most. Edit shows the handles; Done puts the swipes back.
    @State private var isReordering = false
    /// The Related tab's lists, for the song they were found for.
    @State private var related: [(kind: SimilarKind, songs: [Song])] = []
    @State private var isLoadingRelated = false

    private enum Tab: String, CaseIterable {
        case earlier = "Earlier"
        case upNext = "Up Next"
        /// Plexamp's, and the desktop's: tracks like the one playing, following it.
        case related = "Related"
    }

    private var player: PlaybackController { appState.player }

    var body: some View {
        // The header is each list's own pinned section header, not a view above the
        // list. Reordering only scrolls while the dragged row is inside the list, so
        // with the header outside, dragging a song "all the way up" put the finger over
        // the header, outside the list, and the scrolling stopped -- it moved only while
        // held a little lower. Inside, the top of the list is the top of the header.
        Group {
            switch tab {
            case .upNext: upNextList
            case .earlier: earlierList
            case .related: relatedList
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

    /// Each list's section header. Pinned, as a plain list's headers are, so it stays at
    /// the top while the rows scroll under it.
    private var pinnedHeader: some View {
        header
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            .listRowInsets(EdgeInsets())
            .textCase(nil)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Queue", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)

            Spacer(minLength: 0)

            if tab == .upNext, player.queue.upNextCount > 1 {
                Button(isReordering ? "Done" : "Edit") {
                    withAnimation { isReordering.toggle() }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
            }

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
            Section {
                if !player.queue.sourceDescription.isEmpty, player.queue.hasUpNext {
                    Text("Playing from \(player.queue.sourceDescription)")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .listRowBackground(Color.clear)
                        .moveDisabled(true)
                }

                // Swipe left to remove, right to play next. Neither works while the drag
                // handles show (Edit), so the long-press menu has both too.
                ForEach(upNextWithIndices, id: \.orderIndex) { entry in
                    row(entry)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                remove(entry)
                            } label: {
                                Label("Remove", systemImage: "minus.circle")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if entry.orderIndex > player.queue.position + 1 {
                                Button {
                                    playNext(entry)
                                } label: {
                                    Label("Play Next", systemImage: "text.insert")
                                }
                                .tint(.appTint)
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
            } header: {
                pinnedHeader
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(isReordering ? .active : .inactive))
        // Nothing left to reorder: the handles go with it.
        .onChange(of: player.queue.upNextCount) { _, count in
            if count < 2 { isReordering = false }
        }
        .overlay {
            if !player.queue.hasUpNext, !(autoplay.isActive && !autoplay.options.isEmpty) {
                placeholder("Nothing queued")
            }
        }
    }

    private var earlierList: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(earlierWithIndices, id: \.orderIndex) { entry in
                        row(entry)
                            .id(entry.orderIndex)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    remove(entry)
                                } label: {
                                    Label("Remove", systemImage: "minus.circle")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    playNext(entry)
                                } label: {
                                    Label("Play Next", systemImage: "text.insert")
                                }
                                .tint(.appTint)
                            }
                    }
                } header: {
                    pinnedHeader
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

    private var relatedList: some View {
        let song = player.currentSong
        return List {
            Section {
                ForEach(related, id: \.kind) { group in
                    Text(group.kind.heading.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .listRowBackground(Color.clear)
                    ForEach(group.songs.indices, id: \.self) { index in
                        PlayableSongRow(
                            songs: group.songs,
                            index: index,
                            source: "\(group.kind.rawValue) · \(song?.title ?? "")",
                            showsNavigation: false
                        )
                        .listRowBackground(Color.clear)
                    }
                }
            } header: {
                pinnedHeader
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if isLoadingRelated, related.isEmpty {
                ProgressView()
            } else if !isLoadingRelated, related.isEmpty {
                placeholder("There isn't another like it.")
            }
        }
        // Follows the track playing, as the desktop's does.
        .task(id: song?.id) {
            guard let song else { related = []; return }
            isLoadingRelated = true
            let found = await appState.similarLists(to: song, limit: 20)
            guard !Task.isCancelled else { return }
            related = found
            isLoadingRelated = false
        }
    }

    private func row(_ entry: (orderIndex: Int, song: Song)) -> some View {
        Button {
            player.jump(toOrderIndex: entry.orderIndex)
        } label: {
            HStack(spacing: 6) {
                SongRow(song: entry.song, style: .withArtwork)
                // The desktop's queue shows each track's stars; a rated one shows here too.
                let rating = userState.rating(entry.song)
                if rating > 0 {
                    Text(String(repeating: "★", count: rating) + String(repeating: "☆", count: 5 - rating))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                        .accessibilityLabel("\(rating) star\(rating == 1 ? "" : "s")")
                }
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
            // The queue's own: these move the song that is already here. The generic
            // Play Next / Add to Queue would add a second copy of it.
            Button("Play Now", systemImage: "play.fill") {
                player.jump(toOrderIndex: entry.orderIndex)
            }
            if entry.orderIndex != player.queue.position + 1 {
                Button("Play Next", systemImage: "text.insert") { playNext(entry) }
            }
            if entry.orderIndex < player.queue.order.count - 1 {
                Button("Move to End", systemImage: "text.append") { moveToEnd(entry) }
            }
            Button("Remove from Queue", systemImage: "minus.circle", role: .destructive) {
                remove(entry)
            }
            Divider()
            SongMenu(song: entry.song, showsNavigation: false, showsQueueItems: false)
            Divider()
            SongJumpItems(song: entry.song)
        }
    }

    /// Straight after the track playing -- moved there, from Up Next or from Earlier.
    private func playNext(_ entry: (orderIndex: Int, song: Song)) {
        guard let index = stillHolds(entry) else { return }
        player.moveInQueue(from: index, to: player.queue.position + 1)
    }

    private func moveToEnd(_ entry: (orderIndex: Int, song: Song)) {
        guard let index = stillHolds(entry) else { return }
        player.moveToEnd(fromOrderIndex: index)
    }

    /// The menu was built for one row. If the queue shifted while it was open -- a DJ
    /// pick or a station top-up landing ahead of it -- that index is now some other
    /// song, so it is only acted on while it still holds this one.
    private func remove(_ entry: (orderIndex: Int, song: Song)) {
        guard let index = stillHolds(entry) else { return }
        player.removeFromQueue(orderIndex: index)
    }

    /// The row's place, if the queue still has this song there.
    private func stillHolds(_ entry: (orderIndex: Int, song: Song)) -> Int? {
        let queue = player.queue
        guard queue.order.indices.contains(entry.orderIndex),
              queue.tracks.indices.contains(queue.order[entry.orderIndex]),
              queue.tracks[queue.order[entry.orderIndex]].id == entry.song.id
        else { return nil }
        return entry.orderIndex
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
