import SwiftUI

/// Cover art. Probes the memory cache synchronously so a cached image renders on
/// the first frame with no placeholder flash; only a genuine miss fades in.
struct ArtworkImage: View {
    @Environment(ArtworkStore.self) private var store
    @Environment(PlaylistArtwork.self) private var playlistArtwork

    let id: String?
    var size: ArtworkStore.Size = .card
    var cornerRadius: CGFloat = Metrics.radiusCard
    /// When set, a locally chosen image for this playlist wins over `id`.
    var playlistID: String?
    /// Album or playlist name, used to draw initials when there is no art.
    ///
    /// 274 of this library's 2,227 albums have no cover anywhere — not embedded, not a
    /// `cover.jpg` beside the tracks — and a grid of identical grey music notes is the
    /// worst possible way to show that. Initials at least tell them apart.
    var fallbackText: String?

    /// The loaded image and what it was loaded for. A list that identifies its rows by
    /// position hands this view a different cover id when the list changes, and an image
    /// kept without its key went on showing the old cover until the new one arrived:
    /// another album's art on a track.
    @State private var loaded: Loaded?

    private struct Loaded {
        let key: String
        let image: UIImage
    }

    private var loadKey: String {
        "\(id ?? "")|\(playlistID ?? "")|\(playlistArtwork.generation)"
    }

    var body: some View {
        // `Color.clear` plus an **overlay**, not a `ZStack`, and that distinction is the
        // whole reason non-square covers used to break the layout.
        //
        // `scaledToFill` sizes a view to *cover* what it was offered, so for art that is
        // not square it reports a size larger than the space it was given -- "My Old Ways"
        // is 600x542, which came back 10.7% too wide. `.clipped()` only clips the
        // drawing; it does nothing to the reported size. Anywhere that size was trusted
        // rather than pinned with an explicit frame -- the player's artwork mode, the
        // album and playlist headers -- the whole screen grew, so the art looked
        // zoomed-in and the controls under it were pushed off the bottom.
        //
        // `Color.clear` takes exactly the space offered and an overlay is sized by its
        // parent and can never enlarge it, so this now fills its slot, crops the overflow,
        // and cannot move anything around it.
        //
        // The memory cache is asked here as well as in `load()`, so a cover already in
        // memory is drawn on the first frame. Asked only in `.task`, which runs once the
        // view is on screen, every cell scrolled into view drew its placeholder first --
        // monogram scaled down from 200 points and all -- and then drew again with the
        // image. Not for a playlist, whose own photo, read from disk, wins over the cover.
        //
        // And while this size loads, the same cover at another size if one is in memory:
        // the grid's cover in the player, a row's thumbnail in a grid. Soft for a moment
        // is far better than a grey square.
        let key = loadKey
        let current = loaded?.key == key ? loaded?.image : nil
        let shown = current ?? (playlistID == nil
            ? store.cached(id, size) ?? store.cachedStandIn(id, for: size)
            : nil)

        Color.clear
            .overlay {
                if let image = shown {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholder
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            // Re-reads when a playlist photo is set or cleared, which changes no id.
            .task(id: key) {
                await load(key)
            }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let monogram = fallbackText?.monogram, !monogram.isEmpty {
                    // Scaled to the box rather than a fixed size: the same view draws a
                    // 40pt row thumbnail and a 300pt header.
                    Text(monogram)
                        .font(.system(size: 200, weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.01)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .padding(8)
                } else {
                    Image(systemName: "music.note")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
    }

    private func load(_ key: String) async {
        // A chosen playlist photo takes precedence, and is read straight from disk --
        // it is already local, so there is nothing to await.
        if let playlistID, let custom = playlistArtwork.image(for: playlistID) {
            loaded = Loaded(key: key, image: custom)
            return
        }

        if let hit = store.cached(id, size) {
            loaded = Loaded(key: key, image: hit)
            return
        }

        guard let image = await store.image(for: id, size: size), !Task.isCancelled else { return }
        loaded = Loaded(key: key, image: image)
    }
}

/// Circular variant for artists.
struct ArtistArtwork: View {
    @Environment(ArtworkStore.self) private var store

    let id: String?
    var diameter: CGFloat
    var initials: String?

    @State private var image: UIImage?

    var body: some View {
        // From memory on the first frame when it is there, as `ArtworkImage` does.
        let shown = image ?? store.cached(id, .thumb)

        ZStack {
            if let image = shown {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(.quaternary)
                    .overlay {
                        // Navidrome without a Last.fm key returns no artist image,
                        // so a monogram is the common case rather than the fallback.
                        Text(initials ?? "?")
                            .font(.system(size: diameter * 0.36, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .task(id: id) {
            if let hit = store.cached(id, .thumb) {
                image = hit
                return
            }
            image = nil
            let loaded = await store.image(for: id, size: .thumb)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { image = loaded }
        }
    }
}

extension String {
    /// "Red Hot Chili Peppers" -> "RH"
    var monogram: String {
        let words = split(separator: " ").prefix(2)
        return words.compactMap { $0.first }.map(String.init).joined().uppercased()
    }
}

