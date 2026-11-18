import SwiftUI
import UIKit
import WatchKit

/// Music on the watch: a remote for the phone (what is playing, play, pause, skip, the
/// heart, any pinned playlist, mix or playlist to start), and playlists kept on the watch
/// to play with no phone at all, to AirPods.
@main
struct MusicWatchApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(WatchModel.shared)
                .environment(WatchPlayer.shared)
                .tint(.watchPink)
        }
    }
}

extension Color {
    static let watchPink = Color(red: 0.98, green: 0.28, blue: 0.36)
}

struct RootView: View {
    @Environment(WatchModel.self) private var model
    @Environment(WatchPlayer.self) private var watchPlayer

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { RemoteView() } label: { PhoneRow() }
                    if watchPlayer.hasStarted, let track = watchPlayer.current {
                        NavigationLink { NowPlayingView() } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(track.title).lineLimit(1)
                                    Text("On Watch").font(.caption2).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: watchPlayer.isPlaying ? "applewatch.radiowaves.left.and.right" : "applewatch")
                            }
                        }
                    }
                }

                if !model.collections.isEmpty {
                    Section("On Watch") {
                        ForEach(model.collections) { collection in
                            NavigationLink { CollectionView(id: collection.id) } label: {
                                VStack(alignment: .leading) {
                                    Text(collection.name).lineLimit(1)
                                    Text(collection.isComplete
                                         ? "\(collection.tracks.count) songs"
                                         : "\(collection.tracks.count) of \(collection.total) here")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                section("Pinned", model.state.pinned)
                section("Made for You", model.state.mixes)
                section("Playlists", model.state.playlists)
            }
            .navigationTitle("Music")
            .overlay(alignment: .bottom) { notice }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [WatchLink.Item]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    NavigationLink { ItemView(item: item) } label: {
                        VStack(alignment: .leading) {
                            Text(item.name).lineLimit(2)
                            if let detail = item.detail {
                                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var notice: some View {
        if let text = model.notice {
            Text(text)
                .font(.footnote)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .task(id: text) {
                    try? await Task.sleep(for: .seconds(2))
                    model.notice = nil
                }
        }
    }
}

/// The phone's song, in the list.
private struct PhoneRow: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        Label {
            VStack(alignment: .leading) {
                Text(model.state.title ?? "Nothing playing").lineLimit(1)
                Text(model.state.artist ?? "iPhone").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        } icon: {
            Image(systemName: model.state.isPlaying ? "iphone.radiowaves.left.and.right" : "iphone")
        }
    }
}

/// A remote for the phone: the cover, the song, its progress, the controls and the heart.
struct RemoteView: View {
    @Environment(WatchModel.self) private var model

    private var state: WatchLink.State { model.state }

    private var span: ClosedRange<Date>? {
        guard state.isPlaying, state.duration > 0 else { return nil }
        let start = state.anchor.addingTimeInterval(-state.elapsed)
        return start...start.addingTimeInterval(state.duration)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                cover.frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 0) {
                    Text(state.title ?? "Nothing playing").font(.headline).lineLimit(1)
                    Text(state.artist ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Group {
                if let span {
                    ProgressView(timerInterval: span, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                } else {
                    ProgressView(value: state.duration > 0 ? min(state.elapsed / state.duration, 1) : 0)
                }
            }
            .progressViewStyle(.linear)
            HStack {
                control("backward.fill", .previous)
                control(state.isPlaying ? "pause.fill" : "play.fill", .toggle, large: true)
                control("forward.fill", .next)
            }
            HStack {
                Button { model.send(.favourite) } label: {
                    Image(systemName: state.isFavourite ? "heart.fill" : "heart")
                        .foregroundStyle(state.isFavourite ? Color.watchPink : .primary)
                }
                Spacer()
                ForEach(1...5, id: \.self) { value in
                    Button { model.send(.rate(value)) } label: {
                        Image(systemName: value <= state.rating ? "star.fill" : "star")
                            .font(.system(size: 11))
                            .foregroundStyle(value <= state.rating ? Color.watchPink : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .navigationTitle("iPhone")
        .overlay(alignment: .bottom) {
            if !model.isReachable {
                Text("iPhone isn't nearby").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let data = model.cover, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.12))
                .overlay { Image(systemName: "music.note").foregroundStyle(.secondary) }
        }
    }

    private func control(_ symbol: String, _ command: WatchLink.Command, large: Bool = false) -> some View {
        Button { model.send(command) } label: {
            Image(systemName: symbol)
                .font(.system(size: large ? 22 : 16, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.plain)
    }
}

/// A playlist or mix: play it on the phone, or keep it on the watch.
struct ItemView: View {
    @Environment(WatchModel.self) private var model
    let item: WatchLink.Item

    private var collection: WatchModel.Collection? { model.collections.first { $0.id == item.id } }

    var body: some View {
        List {
            Button {
                model.send(.play(item))
            } label: {
                Label("Play on iPhone", systemImage: "iphone")
            }
            if let collection {
                NavigationLink { CollectionView(id: collection.id) } label: {
                    Label(collection.isComplete ? "On Watch" : "\(collection.tracks.count) of \(collection.total) on Watch",
                          systemImage: "applewatch")
                }
            } else {
                Button {
                    model.keep(item)
                } label: {
                    Label("Keep on Watch", systemImage: "arrow.down.circle")
                }
            }
        }
        .navigationTitle(item.name)
    }
}

/// Songs kept on the watch: play them here, or take them off.
struct CollectionView: View {
    @Environment(WatchModel.self) private var model
    @Environment(WatchPlayer.self) private var watchPlayer
    @Environment(\.dismiss) private var dismiss
    let id: String

    private var collection: WatchModel.Collection? { model.collections.first { $0.id == id } }

    var body: some View {
        List {
            if let collection {
                if !collection.tracks.isEmpty {
                    Button {
                        Task { await watchPlayer.play(collection.tracks) }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    Button {
                        Task { await watchPlayer.play(collection.tracks, shuffled: true) }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                }
                if !collection.isComplete {
                    Text("\(collection.tracks.count) of \(collection.total) here. The rest arrive while your iPhone is near, fastest on Wi-Fi.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Section {
                    ForEach(Array(collection.tracks.enumerated()), id: \.element.id) { offset, track in
                        Button {
                            Task { await watchPlayer.play(collection.tracks, from: offset) }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(track.title).lineLimit(1)
                                Text(track.artist ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                Button(role: .destructive) {
                    model.remove(id)
                    dismiss()
                } label: {
                    Label("Remove from Watch", systemImage: "trash")
                }
            }
        }
        .navigationTitle(collection?.name ?? "On Watch")
    }
}
