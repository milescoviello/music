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

/// Add to Library for a video: asks, each time, for the song alone or the song and then
/// its album, and sends it through Hermes to the Soulseek pipeline.
struct AddToLibraryModifier: ViewModifier {
    @Environment(MusicRequestService.self) private var requests
    @Binding var video: VideoClient.Video?
    @State private var sentMessage: String?
    @State private var showsSetup = false

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                title,
                isPresented: Binding(get: { video != nil }, set: { if !$0 { video = nil } }),
                titleVisibility: .visible,
                presenting: video
            ) { video in
                Button("Song") { send(video, withAlbum: false) }
                Button("Song + Album") { send(video, withAlbum: true) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Hermes gets it as lossless through Soulseek. The song comes first, so it's playable within minutes.")
            }
            .alert("Music Requests Aren't Set Up", isPresented: $showsSetup) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Add the gateway and its secret in Settings → Music Requests, then try again.")
            }
            .overlay(alignment: .bottom) {
                if let sentMessage {
                    Text(sentMessage)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: sentMessage) {
                            try? await Task.sleep(for: .seconds(3))
                            withAnimation { self.sentMessage = nil }
                        }
                }
            }
            .animation(.snappy, value: sentMessage)
    }

    private var title: String {
        guard let video else { return "Add to Library" }
        let artist = video.artist ?? video.channel
        let song = video.song ?? video.title
        return artist.isEmpty ? "Add “\(song)”" : "Add “\(song)” by \(artist)"
    }

    private func send(_ video: VideoClient.Video, withAlbum: Bool) {
        guard requests.isConfigured else {
            showsSetup = true
            return
        }
        let artist = video.artist ?? video.channel
        let song = video.song ?? video.title
        Task {
            let accepted = await requests.sendSong(artist: artist, title: song, withAlbum: withAlbum, videoID: video.id)
            sentMessage = accepted
                ? (withAlbum ? "Asked for “\(song)”, then its album" : "Asked for “\(song)”")
                : (requests.lastError ?? "The request didn't go through.")
        }
    }
}

extension View {
    func addToLibrary(_ video: Binding<VideoClient.Video?>) -> some View {
        modifier(AddToLibraryModifier(video: video))
    }
}
