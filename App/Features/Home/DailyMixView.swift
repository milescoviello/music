import SwiftUI

/// A daily mix, opened from Home.
///
/// The mix is held by `DailyMixes` rather than passed through the route, so the route
/// stays a plain string and a mix rebuilt underneath the screen is picked up rather than
/// frozen at push time.
struct DailyMixView: View {
    @Environment(AppState.self) private var appState

    let mixID: String

    @Environment(LibraryScopeStore.self) private var scope
    /// The same setting the shelf uses, so an extension draws from the same libraries.
    @AppStorage(LibraryScopeStore.mixesKey) private var mixFolderID = -1

    private var mix: DailyMixes.Mix? { appState.mixes.mix(id: mixID) }

    private var mixScope: LibraryScope {
        scope.scope(forFolderID: mixFolderID)
    }

    var body: some View {
        Group {
            if let mix {
                List {
                    Section {
                        header(mix)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }

                    ForEach(Array(mix.songs.enumerated()), id: \.offset) { index, _ in
                        PlayableSongRow(songs: mix.songs, index: index, source: mix.title)
                            // Fetching starts ten rows early rather than at the very
                            // bottom, so the next batch is usually already there by the
                            // time it is scrolled to. A spinner you actually wait on is
                            // the thing being avoided here.
                            .task(id: mix.songs.count) {
                                guard index == max(0, mix.songs.count - 10) else { return }
                                appState.mixes.extend(
                                    mixID: mixID, appState: appState, scope: mixScope
                                )
                            }
                    }

                    // A mix is a station, not a 25-track list: the bottom asks for more of
                    // the same, and when the recipe's pool is spent it carries on as radio
                    // seeded from what is already here.
                    if mix.isExhausted != true {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Adding more…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .task {
                            appState.mixes.extend(
                                mixID: mixID, appState: appState, scope: mixScope
                            )
                        }
                    }
                }
                .listStyle(.plain)
        .playerClearance()
                .collapsingTitle(mix.title)
            } else {
                // Only reachable if the mixes were rebuilt for a different day or folder
                // while this screen sat in the stack.
                ContentUnavailableView(
                    "Mix Not Available",
                    systemImage: "sparkles",
                    description: Text("This mix has been replaced by today's.")
                )
            }
        }
    }

    @ViewBuilder
    private func header(_ mix: DailyMixes.Mix) -> some View {
        VStack(spacing: Metrics.itemSpacing) {
            MixTile(covers: mix.covers, size: .card)
                .frame(width: 220, height: 220)
                .padding(.top, Metrics.itemSpacing)

            VStack(spacing: 4) {
                Text(mix.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("\(mix.songs.count) songs · \(mix.subtitle)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            PlayShuffleButtons(
                onPlay: { play(mix, shuffled: false) },
                onShuffle: { play(mix, shuffled: true) }
            )

            Button {
                appState.downloads.download(mix.songs, groupID: "mix-\(mix.id)", groupName: mix.title)
            } label: {
                Label("Download Mix", systemImage: "arrow.down.circle")
                    .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Metrics.gutter)
        .padding(.bottom, Metrics.itemSpacing)
    }

    private func play(_ mix: DailyMixes.Mix, shuffled: Bool) {
        appState.player.play(songs: mix.songs, startingAt: 0, source: mix.title, shuffled: shuffled)
    }
}

/// Four covers in a square, or one if that is all there is.
///
/// Deliberately not an album cover: a mix is not a record, and a single sleeve would make
/// the shelf look like another row of albums.
struct MixTile: View {
    let covers: [String]
    var size: ArtworkStore.Size = .thumb
    var cornerRadius: CGFloat = Metrics.radiusCard

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            if covers.count >= 4 {
                LazyVGrid(
                    columns: [GridItem(.fixed(side / 2), spacing: 0), GridItem(.fixed(side / 2), spacing: 0)],
                    spacing: 0
                ) {
                    ForEach(covers.prefix(4), id: \.self) { cover in
                        ArtworkImage(id: cover, size: size, cornerRadius: 0)
                            .frame(width: side / 2, height: side / 2)
                    }
                }
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                ArtworkImage(id: covers.first, size: size, cornerRadius: cornerRadius)
                    .frame(width: side, height: side)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
