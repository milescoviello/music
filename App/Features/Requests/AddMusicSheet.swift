import SwiftUI

/// Asks, each time, which library it goes to (and for a song, whether its album comes
/// too); then either sends it, for the server to pick the best lossless copy, or waits for
/// the search and shows every copy found to pick from.
struct AddMusicSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let item: AddMusicItem
    /// Called with what was sent, for the screen behind to say so.
    var onSent: (String) -> Void = { _ in }

    @State private var library = SonicClient.Library.music
    @State private var albumToo = false
    @State private var isSending = false
    @State private var error: String?
    /// The request whose copies are being picked from.
    @State private var picking: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: Metrics.itemSpacing) {
                        cover
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusThumb, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.headline).lineLimit(2)
                            Text(item.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            Text(kindLine).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }

                if item.asksForLibrary {
                    Section("Add To") {
                        Picker("Library", selection: $library) {
                            Text("Music").tag(SonicClient.Library.music)
                            Text("My Music").tag(SonicClient.Library.myMusic)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }

                if case .song = item {
                    Section {
                        Toggle("Also Get Its Album", isOn: $albumToo)
                    } footer: {
                        Text("The song comes first, so it plays within minutes.")
                    }
                }

                Section {
                    Button {
                        Task { await send(choose: false) }
                    } label: {
                        Label(item.isLossless ? "Get It Lossless" : "Add", systemImage: "arrow.down.circle")
                    }
                    Button {
                        Task { await send(choose: true) }
                    } label: {
                        Label("Choose the Copy…", systemImage: "list.bullet.rectangle")
                    }
                } footer: {
                    Text(footer)
                }
                .disabled(isSending)

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(item.isAlbum ? "Get the Album" : "Get the Song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if isSending {
                    ToolbarItem(placement: .confirmationAction) { ProgressView() }
                }
            }
            .navigationDestination(item: $picking) { id in
                RequestDetailView(requestID: id, onStarted: {
                    onSent("Getting “\(item.title)”")
                    dismiss()
                })
            }
        }
        .onAppear {
            library = appState.grab.lastLibrary
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let url = item.cover {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
        } else {
            ArtworkImage(id: item.coverArt, size: .thumb, cornerRadius: Metrics.radiusThumb)
        }
    }

    private var kindLine: String {
        switch item {
        case .song: "Song"
        case let .album(_, _, year, _, _): ["Album", year].compactMap { $0 }.joined(separator: " · ")
        case .fullAlbum: "The album this song is on"
        case .lossless: "In your library as \(item.losslessFrom)"
        }
    }

    private var footer: String {
        if item.isLossless {
            return "A lossless copy replaces the file where it is, keeping its plays, stars and tags."
        }
        return "Only lossless copies, from Soulseek. Add takes the best one; Choose the Copy shows every one found."
    }

    private func send(choose: Bool) async {
        isSending = true
        error = nil
        defer { isSending = false }
        do {
            let request = try await appState.grab.ask(item.ask(library: library, choose: choose, albumToo: albumToo))
            if choose {
                picking = request.id
            } else {
                onSent(albumToo ? "Getting “\(item.title)”, then its album" : "Getting “\(item.title)”")
                dismiss()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private extension AddMusicItem {
    var isLossless: Bool {
        if case .lossless = self { return true }
        return false
    }

    var losslessFrom: String {
        if case let .lossless(song) = self { return song.suffix?.uppercased() ?? "a lossy file" }
        return ""
    }
}

/// `.addMusic($item)`: the Add sheet for whatever is set, and a moment's word once it is sent.
struct AddMusicModifier: ViewModifier {
    @Binding var item: AddMusicItem?
    @State private var sent: String?

    func body(content: Content) -> some View {
        content
            .sheet(item: $item) { item in
                AddMusicSheet(item: item) { sent = $0 }
                    .presentationDetents([.medium, .large])
            }
            .overlay(alignment: .bottom) {
                if let sent {
                    NavigationLink(value: Destination.requests) {
                        Label(sent, systemImage: "arrow.down.circle")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    // Clear of the tab bar and the mini player.
                    .padding(.bottom, 120)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: sent) {
                        try? await Task.sleep(for: .seconds(4))
                        withAnimation { self.sent = nil }
                    }
                }
            }
            .animation(.snappy, value: sent)
    }
}

extension View {
    func addMusic(_ item: Binding<AddMusicItem?>) -> some View {
        modifier(AddMusicModifier(item: item))
    }
}
