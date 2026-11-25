import SwiftUI

/// The bar above the tab bar. The whole thing is the tap target.
struct MiniPlayerBar: View {
    @Environment(AppState.self) private var appState
    @Environment(RemotePlayers.self) private var remotes
    @Binding var showsPlayer: Bool
    /// True when hosted in the tab bar's accessory slot, which draws its own
    /// background and separator -- drawing a second one there looks like a seam.
    var isSystemAccessory = false

    private var player: PlaybackController { appState.player }
    private var videos: VideoService { appState.video }
    /// A YouTube result shrunk in here: the bar shows it playing, a tap brings it back full
    /// screen, and the cross closes it, putting the music back.
    private var minimizedVideo: VideoClient.Video? {
        videos.isWatchingMinimized ? videos.watching : nil
    }

    var body: some View {
        // A video shrunk in here shows even with no song loaded: hidden, it would play on
        // with no way back to it.
        if player.currentSong != nil || minimizedVideo != nil {
            let song = player.currentSong
            VStack(spacing: 0) {
                if !isSystemAccessory {
                    Divider()
                }

                HStack(spacing: Metrics.itemSpacing) {
                    if minimizedVideo != nil {
                        // The video itself, live: also what floats as Picture in Picture
                        // when the app is left.
                        VideoSurface(engine: videos.engine, fills: true)
                            .frame(width: Metrics.thumbSmall * 16 / 9, height: Metrics.thumbSmall)
                            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusThumb, style: .continuous))
                            .accessibilityHidden(true)
                    } else {
                        ArtworkImage(
                            id: song?.coverArt,
                            size: .thumb,
                            cornerRadius: Metrics.radiusThumb
                        )
                        .frame(width: Metrics.thumbSmall, height: Metrics.thumbSmall)
                    }

                    // One line only: 56pt with two lines is cramped, and the artist
                    // is one tap away in the full player.
                    Text(minimizedVideo?.title ?? song?.title ?? "")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)

                    // Playing on a computer, not here.
                    if let session = remotes.session {
                        Image(systemName: "desktopcomputer")
                            .font(.caption)
                            .foregroundStyle(Color.appTint)
                            .accessibilityLabel("Playing on \(session.computer.name)")
                    }

                    Spacer(minLength: 8)

                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(minWidth: Metrics.minimumTouchTarget, minHeight: Metrics.minimumTouchTarget)
                    }
                    .buttonStyle(.plain)

                    if minimizedVideo != nil {
                        Button {
                            videos.stopWatching()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.title3)
                                .frame(minWidth: Metrics.minimumTouchTarget, minHeight: Metrics.minimumTouchTarget)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close video")
                    } else {
                        Button {
                            player.next()
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.title3)
                                .frame(minWidth: Metrics.minimumTouchTarget, minHeight: Metrics.minimumTouchTarget)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, isSystemAccessory ? 8 : Metrics.gutter)
                .frame(height: isSystemAccessory ? nil : Metrics.miniPlayerHeight)
                .background(isSystemAccessory ? AnyShapeStyle(.clear)
                                              : AnyShapeStyle(.ultraThinMaterial))
                .contentShape(Rectangle())
                .onTapGesture {
                    if minimizedVideo != nil { videos.expandWatching() } else { showsPlayer = true }
                }
                // Swipe up to expand, sideways to skip -- the gestures Plexamp and
                // Apple Music both use.
                .gesture(
                    // Local is fine here: this bar is not moved by its own gesture, so
                    // there is no moving ruler to correct for.
                    DragGesture(minimumDistance: 20)
                        .onEnded { value in
                            if minimizedVideo != nil {
                                if value.translation.height < -30 { videos.expandWatching() }
                            } else if value.translation.height < -30 {
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
