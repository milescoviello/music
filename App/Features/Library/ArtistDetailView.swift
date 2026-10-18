import SwiftUI

/// A `ScrollView` rather than a `List`, because the content is heterogeneous --
/// header, buttons, a top-songs block, then album rows -- and forcing that into a
/// List fights it.
struct ArtistDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope

    let artist: ArtistRef

    @State private var detail: ArtistDetail?
    /// World popularity first, then the rest of the catalogue.
    ///
    /// `getTopSongs` really is a global chart — Last.fm's, through Navidrome's agent — and
    /// asked for 50 it returns 50: Tame Impala comes back led by *Loser* and *Dracula*, its
    /// current singles, not by anything this library has played. What it is bad at is
    /// *matching* that chart to local files: Nirvana has 67 tracks here and one matched,
    /// Radiohead 322 and three, because Last.fm's titles and the library's disagree about
    /// remaster suffixes and punctuation.
    ///
    /// So the chart supplies the head of the list and the catalogue supplies the tail,
    /// ordered by this library's own play counts. The top rows are the ones other players
    /// would show, and the list still goes all the way down.
    @State private var popular: [Song] = []
    @State private var isGatheringDiscography = false
    /// Grows five at a time. A 322-track wall would bury the Albums section under it, and
    /// "all of it or nothing" is a worse choice than "a bit more".
    @State private var visiblePopularCount = ArtistDetailView.popularStep

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.shelfSpacing) {
                header

                if !popular.isEmpty {
                    VStack(alignment: .leading, spacing: Metrics.headerToContent) {
                        Text("Popular")
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, Metrics.gutter)

                        // `PlayableSongRow`, so a tap plays the list from that point and the
                        // menu, star, rating and download all come free — the hand-rolled
                        // Button/SongRow pair this replaces had only tap-to-play.
                        // The row's index is into the *whole* ordered list, so tapping the
                        // third one plays from there through everything below it in
                        // popularity order — collapsed or not.
                        ForEach(Array(visiblePopular.enumerated()), id: \.offset) { index, _ in
                            PlayableSongRow(
                                songs: popular,
                                index: index,
                                source: artist.name,
                                showsNavigation: false
                            )
                            .padding(.horizontal, Metrics.gutter)
                            .padding(.vertical, 6)
                        }

                        if popular.count > Self.popularStep {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if hiddenPopularCount == 0 {
                                        visiblePopularCount = Self.popularStep
                                    } else {
                                        visiblePopularCount += Self.popularStep
                                    }
                                }
                            } label: {
                                Label(
                                    hiddenPopularCount == 0
                                        ? "Show less"
                                        : "Show \(min(Self.popularStep, hiddenPopularCount)) more",
                                    systemImage: hiddenPopularCount == 0
                                        ? "chevron.up"
                                        : "chevron.down"
                                )
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, Metrics.gutter)
                                .padding(.vertical, 8)
                            }
                        }
                    }
                }

                if let albums = detail?.albums, !albums.isEmpty {
                    VStack(alignment: .leading, spacing: Metrics.headerToContent) {
                        Text("Albums")
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, Metrics.gutter)

                        // Rows, not a grid: denser and more scannable for the
                        // 1-30 albums an artist actually has.
                        ForEach(albums) { album in
                            NavigationLink(value: Destination.album(AlbumRef(album))) {
                                HStack(spacing: Metrics.itemSpacing) {
                                    ArtworkImage(
                                        id: album.coverArt,
                                        size: .thumb,
                                        cornerRadius: Metrics.radiusThumb
                                    )
                                    .frame(width: Metrics.thumbRow, height: Metrics.thumbRow)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(album.name)
                                            .lineLimit(1)
                                            .foregroundStyle(.primary)
                                        if let year = album.year {
                                            Text(String(year))
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    Spacer(minLength: 8)

                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, Metrics.gutter)
                                .frame(minHeight: 60)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .collapsingTitle(artist.name)
        .playerClearance()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                FavoriteButton(
                    id: artist.id,
                    kind: .artist,
                    serverValue: detail?.starred != nil
                )
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    startArtistRadio()
                } label: {
                    Image(systemName: "dot.radiowaves.left.and.right")
                }
                .disabled(isGatheringDiscography)
                .accessibilityLabel("Start artist radio")
            }
        }
        .task { await load() }
    }

    private var header: some View {
        VStack(spacing: Metrics.headerToContent) {
            ArtistArtwork(
                id: detail?.coverArt ?? artist.coverArt,
                diameter: 112,
                initials: artist.name.monogram
            )

            VStack(spacing: 4) {
                Text(artist.name)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                if let count = detail?.albumCount {
                    Text("\(count) albums")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            PlayShuffleButtons(
                onPlay: { playDiscography(shuffled: false) },
                onShuffle: { playDiscography(shuffled: true) },
                isBusy: isGatheringDiscography
            )
            .padding(.horizontal, Metrics.gutter)

            // Where a biography would go if the server had one. It does not: this
            // server's `getArtistInfo2` returns no text at all and its image URLs 404.
            HermesNoteSection(
                subject: .artist(id: artist.id, name: artist.name),
                isCompact: true
            )
            .padding(.horizontal, Metrics.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Metrics.gutter)
    }

    static let popularStep = 5

    private var visiblePopular: [Song] {
        Array(popular.prefix(visiblePopularCount))
    }

    private var hiddenPopularCount: Int {
        max(0, popular.count - visiblePopularCount)
    }

    /// Plays the catalogue already in hand. It used to gather every album on the spot —
    /// the same requests the Popular list now makes on load — so pressing Play meant
    /// waiting for a fetch that had already happened.
    private func playDiscography(shuffled: Bool) {
        guard !popular.isEmpty else { return }
        appState.player.play(
            songs: popular, startingAt: 0, source: artist.name, shuffled: shuffled
        )
    }

    private func startArtistRadio() {
        guard !isGatheringDiscography else { return }
        isGatheringDiscography = true
        Task {
            let mix = await appState.radio.artistMix(artist, scope: scope.scope)
            isGatheringDiscography = false
            appState.startRadio(
                named: "\(artist.name) Radio", songs: mix,
                station: .artistMix(ids: [artist.id], names: [artist.name])
            )
        }
    }

    private func load() async {
        detail = try? await appState.client.artistDetail(id: artist.id)

        isGatheringDiscography = true
        defer { isGatheringDiscography = false }

        // The chart and the catalogue at once: the chart is one request, the catalogue is
        // one per album and cached, so a second visit is instant and the page still fills in
        // offline.
        let client = appState.client
        let id = artist.id
        let name = artist.name

        async let chart = try? client.topSongs(artist: name, count: 50)
        async let catalogue: [Song]? = appState.cached(CacheKey.artistSongs(id)) {
            try await client.artistSongs(id: id)
        }

        popular = Self.ordered(chart: await chart ?? [], catalogue: await catalogue ?? [])
    }

    /// The chart's order, then everything it missed by play count.
    ///
    /// Ties in the tail — which is *every* track for an artist never played — keep the
    /// catalogue's release-then-track order, so the list does not reshuffle between visits.
    static func ordered(chart: [Song], catalogue: [Song]) -> [Song] {
        var seen: Set<String> = []
        var result: [Song] = []

        for song in chart where seen.insert(song.id).inserted {
            result.append(song)
        }

        let rest = catalogue.enumerated()
            .filter { !seen.contains($0.element.id) }
            .sorted { left, right in
                let a = left.element.playCount ?? 0
                let b = right.element.playCount ?? 0
                return a == b ? left.offset < right.offset : a > b
            }
            .map(\.element)

        return result + rest
    }
}
