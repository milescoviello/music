import SwiftUI

/// "Add to Playlist…", offered wherever a song or a set of songs is.
///
/// A sheet now, not the submenu it was. A submenu closes at the first tap, so it could add
/// to one playlist only, and it is drawn before it opens, so it could not say which
/// playlists already had the song. A menu cannot present a sheet itself, so this asks the
/// store, and the screen on top shows it: see `playlistPicker(host:)`.
struct AddToPlaylistButton: View {
    @Environment(PlaylistStore.self) private var store
    @Environment(\.playlistPickerHost) private var host

    let songs: [Song]
    /// Shown in the "New Playlist…" sheet as the suggested name.
    var suggestedName: String = ""

    var body: some View {
        Button("Add to Playlist…", systemImage: "text.badge.plus") {
            store.picking = .init(songs: songs, suggestedName: suggestedName, host: host)
        }
    }
}

extension EnvironmentValues {
    /// Which screen shows Add to Playlist for the menus inside it.
    @Entry var playlistPickerHost = "root"
}

extension View {
    /// Shows Add to Playlist for the menus inside this view: once over the tabs, which the
    /// player is layered on, and again on any sheet with song menus of its own, because
    /// nothing under a sheet can present above it.
    func playlistPicker(host: String) -> some View {
        modifier(PlaylistPickerHost(name: host))
    }
}

struct PlaylistPickerHost: ViewModifier {
    @Environment(PlaylistStore.self) private var store
    let name: String

    func body(content: Content) -> some View {
        content
            .environment(\.playlistPickerHost, name)
            .sheet(item: Binding(
                get: { store.picking?.host == name ? store.picking : nil },
                set: { if $0 == nil, store.picking?.host == name { store.picking = nil } }
            )) { pick in
                AddToPlaylistSheet(pick: pick)
            }
    }
}

/// Every playlist that can take the songs, each saying how much of them it already has,
/// ticked as many as wanted. One that has them all is shown ticked and cannot be chosen;
/// one that has some is given only the rest. Listed in an order of his own, apart from the
/// Playlists tab's, so the ones he adds to most are at the top: Edit, then drag.
struct AddToPlaylistSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaylistStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let pick: PlaylistStore.Pick

    @State private var chosen: Set<String> = []
    /// By playlist id; absent while it is being read.
    @State private var membership: [String: PlaylistMembership] = [:]
    /// Could not be read, from the server or the saved copy.
    @State private var unreadable: Set<String> = []
    @State private var isNaming = false
    @State private var isAdding = false
    /// Drag handles showing.
    @State private var isArranging = false

    private var arrangement: PlaylistArrangement { appState.playlistArrangement }

    private var subject: String {
        pick.songs.count == 1 ? "“\(pick.songs[0].title)”" : "\(pick.songs.count) songs"
    }

    var body: some View {
        let shown = arrangement.forPicker(store.writable)
        NavigationStack {
            List {
                Section {
                    Button("New Playlist…", systemImage: "plus") { isNaming = true }
                }
                Section {
                    if store.writable.isEmpty {
                        Text(store.isLoading ? "Loading playlists…" : "No playlists yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(shown) { playlist in
                        row(playlist)
                    }
                    .onMove { arrangement.movePicker(from: $0, to: $1, shown: shown) }
                } header: {
                    HStack {
                        Text("Add \(subject) to")
                            .lineLimit(1)
                        Spacer()
                        if shown.count > 1 {
                            Button(isArranging ? "Done" : "Edit") {
                                withAnimation { isArranging.toggle() }
                            }
                            .font(.footnote.weight(.semibold))
                            .textCase(nil)
                            .accessibilityLabel(isArranging ? "Done reordering" : "Reorder playlists")
                        }
                    }
                } footer: {
                    if store.playlists.count > store.writable.count {
                        Text("Smart playlists fill themselves, so they are not listed.")
                    }
                }
            }
            .environment(\.editMode, .constant(isArranging ? .active : .inactive))
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(chosen.count > 1 ? "Add to \(chosen.count)" : "Add", action: add)
                        .disabled(chosen.isEmpty || isAdding)
                }
            }
            // Again when the list changes, for a playlist that was not there before.
            .task(id: store.writable.map(\.id)) {
                await store.refreshIfStale()
                await readMembership()
            }
            .sheet(isPresented: $isNaming) {
                // The new playlist has the songs already, so this is done.
                NewPlaylistSheet(songs: pick.songs, suggestedName: pick.suggestedName) {
                    store.picking = nil
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ playlist: Playlist) -> some View {
        let held = membership[playlist.id]
        let isFull = held?.hasAll == true
        let isOn = isFull || chosen.contains(playlist.id)
        return Button {
            guard !isFull, !isAdding else { return }
            if !chosen.insert(playlist.id).inserted { chosen.remove(playlist.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn && !isFull ? Color.appTint : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .foregroundStyle(isFull ? .secondary : .primary)
                    Text(status(of: playlist, held))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Not while arranging: a disabled row could not be moved either.
        .disabled(!isArranging && (isFull || isAdding))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func status(of playlist: Playlist, _ held: PlaylistMembership?) -> String {
        if let summary = held?.summary { return summary }
        if held == nil, !unreadable.contains(playlist.id) { return "Checking…" }
        let count = playlist.songCount ?? 0
        return "\(count) \(count == 1 ? "song" : "songs")"
    }

    private func readMembership() async {
        let songs = pick.songs
        let unread = store.writable.filter { membership[$0.id] == nil && !unreadable.contains($0.id) }
        await withTaskGroup(of: (String, [Song]?).self) { group in
            for playlist in unread {
                group.addTask { [store] in (playlist.id, await store.entries(of: playlist)) }
            }
            for await (id, entries) in group {
                if let entries {
                    membership[id] = PlaylistMembership(of: songs, in: entries)
                } else {
                    unreadable.insert(id)
                }
            }
        }
    }

    private func add() {
        isAdding = true
        let targets = arrangement.forPicker(store.writable).filter { chosen.contains($0.id) }
        Task {
            await store.add(pick.songs, to: targets)
            store.picking = nil
        }
    }
}

struct NewPlaylistSheet: View {
    @Environment(PlaylistStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let songs: [Song]
    var suggestedName: String = ""
    /// After the playlist is made, before this closes.
    var onCreated: (() -> Void)?

    @State private var name = ""
    @State private var isSaving = false
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Playlist name", text: $name)
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                } footer: {
                    if songs.isEmpty {
                        Text("An empty playlist you can add to later.")
                    } else {
                        Text("\(songs.count) \(songs.count == 1 ? "song" : "songs") will be added.")
                    }
                }
            }
            .navigationTitle("New Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
            .onAppear {
                name = suggestedName
                isFocused = true
            }
        }
        // Short, because it is one field. A full-height sheet for one text field looks
        // like something went wrong.
        .presentationDetents([.height(220)])
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSaving = true
        Task {
            await store.create(name: name, songs: songs)
            onCreated?()
            dismiss()
        }
    }
}

/// Rename / edit the description of an existing playlist.
struct EditPlaylistSheet: View {
    @Environment(PlaylistStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let playlist: Playlist

    @State private var name: String
    @State private var comment: String

    init(playlist: Playlist) {
        self.playlist = playlist
        _name = State(initialValue: playlist.name)
        _comment = State(initialValue: playlist.comment ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Playlist name", text: $name)
                }
                Section("Description") {
                    TextField("Optional", text: $comment, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .navigationTitle("Edit Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await store.rename(
                                playlist,
                                to: name,
                                comment: comment.isEmpty ? nil : comment
                            )
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
