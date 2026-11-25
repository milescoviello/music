import AVFoundation
import SwiftUI
import UIKit

/// The video's picture: an `AVPlayerLayer` on the engine's one player. Several can exist at
/// once (the player and its full-screen view); each shows the same video.
struct VideoSurface: UIViewRepresentable {
    let engine: VideoEngine
    var fills = false

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .black
        // Touches go to the SwiftUI around it (taps, the player's pull-down), never here.
        view.isUserInteractionEnabled = false
        view.engine = engine
        view.playerLayer.videoGravity = fills ? .resizeAspectFill : .resizeAspect
        engine.attach(view.playerLayer)
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.playerLayer.videoGravity = fills ? .resizeAspectFill : .resizeAspect
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
        view.engine?.detach(view.playerLayer)
    }

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        // swiftlint:disable:next force_cast
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        weak var engine: VideoEngine?
    }
}

/// A video's thumbnail, 16:9, with its length in the corner the way YouTube shows it.
struct VideoThumbnail: View {
    @Environment(VideoService.self) private var videos
    let video: VideoClient.Video

    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                AsyncImage(url: videos.client.thumbnailURL(videoID: video.id)) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary)
                            .overlay { Image(systemName: "play.rectangle").foregroundStyle(.tertiary) }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusThumb, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if let length = video.durationText {
                    Text(length)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
                        .padding(4)
                }
            }
            .accessibilityHidden(true)
    }
}

/// A video in a list: thumbnail, title, channel and length.
struct VideoRow: View {
    let video: VideoClient.Video
    var isChosen = false
    var badge: String?

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.itemSpacing) {
            VideoThumbnail(video: video)
                .frame(width: 128)
            VStack(alignment: .leading, spacing: 3) {
                Text(video.title)
                    .font(.subheadline.weight(isChosen ? .semibold : .regular))
                    .foregroundStyle(isChosen ? Color.appTint : .primary)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    if video.verified == true {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .accessibilityLabel("Verified channel")
                    }
                    Text(video.subtitle)
                        .lineLimit(1)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.appTint)
                }
            }
            Spacer(minLength: 0)
            if isChosen {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.appTint)
                    .accessibilityLabel("Chosen")
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}

/// Which way the screen may turn. The app is upright everywhere, except while a video is
/// full screen, where it may turn on its side. Read by `AppDelegate`.
@MainActor
enum VideoOrientation {
    private(set) static var allowsLandscape = false

    static var mask: UIInterfaceOrientationMask {
        allowsLandscape ? .allButUpsideDown : .portrait
    }

    static func allowLandscape(_ allowed: Bool) {
        guard allowed != allowsLandscape else { return }
        allowsLandscape = allowed
        for scene in UIApplication.shared.connectedScenes {
            guard let scene = scene as? UIWindowScene else { continue }
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            if !allowed {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
            }
        }
    }
}

/// Add to Library for a video: the Add sheet, for the song -- and its album after it, if
/// wanted -- got lossless from Soulseek by the server.
struct AddToLibraryModifier: ViewModifier {
    @Binding var video: VideoClient.Video?

    func body(content: Content) -> some View {
        content.addMusic(Binding(
            get: {
                video.map { video in
                    .song(artist: video.artist ?? video.channel, title: video.song ?? video.title,
                          seconds: video.duration.map { Int($0) }, videoID: video.id)
                }
            },
            set: { if $0 == nil { video = nil } }
        ))
    }
}

extension View {
    func addToLibrary(_ video: Binding<VideoClient.Video?>) -> some View {
        modifier(AddToLibraryModifier(video: video))
    }
}
