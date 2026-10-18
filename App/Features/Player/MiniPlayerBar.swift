import SwiftUI

/// The bar above the tab bar. The whole thing is the tap target.
struct MiniPlayerBar: View {
    @Environment(AppState.self) private var appState
    @Binding var showsPlayer: Bool
    /// True when hosted in the tab bar's accessory slot, which draws its own
    /// background and separator -- drawing a second one there looks like a seam.
    var isSystemAccessory = false

    private var player: PlaybackController { appState.player }

    var body: some View {
        if let song = player.currentSong {
            VStack(spacing: 0) {
                if !isSystemAccessory {
                    Divider()
                }

                HStack(spacing: Metrics.itemSpacing) {
                    ArtworkImage(
                        id: song.coverArt,
                        size: .thumb,
                        cornerRadius: Metrics.radiusThumb
                    )
                    .frame(width: Metrics.thumbSmall, height: Metrics.thumbSmall)

                    // One line only: 56pt with two lines is cramped, and the artist
                    // is one tap away in the full player.
                    Text(song.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(minWidth: Metrics.minimumTouchTarget, minHeight: Metrics.minimumTouchTarget)
                    }
                    .buttonStyle(.plain)

                    Button {
                        player.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.title3)
                            .frame(minWidth: Metrics.minimumTouchTarget, minHeight: Metrics.minimumTouchTarget)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, isSystemAccessory ? 8 : Metrics.gutter)
                .frame(height: isSystemAccessory ? nil : Metrics.miniPlayerHeight)
                .background(isSystemAccessory ? AnyShapeStyle(.clear)
                                              : AnyShapeStyle(.ultraThinMaterial))
                .contentShape(Rectangle())
                .onTapGesture { showsPlayer = true }
                // Swipe up to expand, sideways to skip -- the gestures Plexamp and
                // Apple Music both use.
                .gesture(
                    // Local is fine here: this bar is not moved by its own gesture, so
                    // there is no moving ruler to correct for.
                    DragGesture(minimumDistance: 20)
                        .onEnded { value in
                            if value.translation.height < -30 {
                                showsPlayer = true
                            } else if value.translation.width < -50 {
                                player.next()
                            } else if value.translation.width > 50 {
                                player.previous()
                            }
                        }
                )
                .overlay(alignment: .bottom) { MiniProgressLine() }
                // Capped, not disabled: the bar is 56pt of chrome above the tab bar, and
                // at accessibility sizes an uncapped title pushes the transport buttons
                // off the edge. Everything on a full screen still scales freely.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
        }
    }
}

/// Reads the controller's 4 Hz elapsed value; a 2pt line needs nothing finer.
///
/// A view of its own so that the tick is read here and nowhere else in the bar: as a
/// property of the bar it relied on the geometry reader's closure being tracked apart
/// from the bar's body, and if it was not, the artwork, title and buttons were rebuilt
/// four times a second on every screen in the app.
private struct MiniProgressLine: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let player = appState.player
        GeometryReader { geometry in
            let fraction = player.duration > 0
                ? min(max(player.elapsed / player.duration, 0), 1)
                : 0
            Rectangle()
                .fill(Color.appTint)
                .frame(width: geometry.size.width * fraction, height: 2)
        }
        .frame(height: 2)
    }
}
