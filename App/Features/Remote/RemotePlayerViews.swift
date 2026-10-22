import SwiftUI

/// The player's "play on" button, beside AirPlay: tinted while a computer is being
/// played to, as Plexamp's is.
struct RemotePlayerButton: View {
    @Environment(RemotePlayers.self) private var remotes
    @State private var showsPicker = false

    var body: some View {
        Button { showsPicker = true } label: {
            Image(systemName: "desktopcomputer")
                .font(.title3)
                .foregroundStyle(remotes.session == nil ? Color.white.opacity(0.6) : Color.appTint)
                .frame(minWidth: Metrics.minimumTouchTarget, minHeight: Metrics.minimumTouchTarget)
        }
        .accessibilityLabel("Play On")
        .accessibilityValue(remotes.session?.computer.name ?? "This iPhone")
        .sheet(isPresented: $showsPicker) {
            RemotePlayerPicker()
        }
    }
}

/// The volume row while a computer is being played to: that computer's volume for the
/// app, since the phone's own buttons and slider move only the phone.
struct RemoteVolumeRow: View {
    let session: RemoteSession
    /// The finger's value while dragging, so the computer's confirmations of earlier steps
    /// do not pull the thumb back.
    @State private var dragging: Double?

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill")
                Slider(
                    value: Binding(
                        get: { dragging ?? session.volume },
                        set: { value in
                            dragging = value
                            session.setVolume(value)
                        }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if !editing { dragging = nil }
                    }
                )
                .tint(.white)
                Image(systemName: "speaker.wave.3.fill")
            }
            Label(caption, systemImage: "desktopcomputer")
                .foregroundStyle(session.status == .connected ? Color.appTint : .secondary)
        }
    }

    private var caption: String {
        let name = session.computer.name
        switch session.status {
        case .connecting: return "Connecting to \(name)…"
        case .connected: return "Playing on \(name)"
        case .reconnecting: return "Reconnecting to \(name)…"
        case .unreachable: return "Can’t reach \(name)"
        }
    }
}

/// The sheet the button opens.
struct RemotePlayerPicker: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RemotePlayerList()
                .navigationTitle("Play On")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

/// This phone and every computer it knows of, to play on. The picker's content, and
/// Settings' Remote Players page.
struct RemotePlayerList: View {
    @Environment(AppState.self) private var appState
    @Environment(RemotePlayers.self) private var remotes

    @State private var code = ""
    @State private var entersCode = false
    @State private var address = ""
    @State private var addsByAddress = false
    /// A computer chosen while this phone is playing: move what is playing, or not.
    @State private var moving: RemotePlayers.Computer?
    @State private var asksToBringBack = false

    var body: some View {
        List {
            Section {
                phoneRow
                ForEach(remotes.computers) { computer in
                    computerRow(computer)
                }
            } footer: {
                Text("Computers on this Wi-Fi with Music open and Remote Control on appear here. The first time, the computer shows a code to type in.")
            }

            Section {
                Button("Add by Address…") {
                    address = ""
                    addsByAddress = true
                }
            } footer: {
                Text("For a network that hides computers from each other. The address is in Settings → Remote Control on the computer.")
            }
        }
        .onAppear { remotes.startBrowsing() }
        .onDisappear { remotes.stopBrowsing() }
        .onChange(of: remotes.pairing) { _, pairing in
            if pairing != nil {
                code = ""
                entersCode = true
            }
        }
        .alert("Enter the Code", isPresented: $entersCode) {
            TextField("123 456", text: $code)
                .keyboardType(.numberPad)
            Button("Pair") {
                let typed = code
                Task { await remotes.finishPairing(code: typed) }
            }
            Button("Cancel", role: .cancel) { remotes.cancelPairing() }
        } message: {
            Text("Type the code \(remotes.pairing?.name ?? "the computer") is showing.")
        }
        .alert("Add a Computer", isPresented: $addsByAddress) {
            TextField("192.168.1.20", text: $address)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add") {
                let typed = address
                Task { await remotes.add(address: typed) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Can’t Play There", isPresented: Binding(
            get: { remotes.problem != nil && !entersCode },
            set: { if !$0 { remotes.problem = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(remotes.problem ?? "")
        }
        .confirmationDialog(
            "Play on \(moving?.name ?? "")",
            isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } }),
            titleVisibility: .visible,
            presenting: moving
        ) { computer in
            Button("Move What’s Playing") { Task { await remotes.select(computer, moving: true) } }
            Button("Just Control It") { Task { await remotes.select(computer) } }
        }
        .confirmationDialog(
            "Play on This iPhone",
            isPresented: $asksToBringBack,
            titleVisibility: .visible
        ) {
            Button("Move What’s Playing Here") { Task { await remotes.playHere(moving: true) } }
            Button("Leave It Playing There") { Task { await remotes.playHere(moving: false) } }
        }
    }

    private var phoneRow: some View {
        Button {
            guard let session = remotes.session else { return }
            if session.mirror.queue.isEmpty {
                Task { await remotes.playHere(moving: false) }
            } else {
                asksToBringBack = true
            }
        } label: {
            row(icon: "iphone", title: "This iPhone", detail: nil, isCurrent: remotes.session == nil)
        }
    }

    private func computerRow(_ computer: RemotePlayers.Computer) -> some View {
        let isCurrent = remotes.session?.computer.id == computer.id
        return Button {
            guard !isCurrent else { return }
            if computer.isPaired, remotes.session == nil, appState.player.hasQueue {
                moving = computer
            } else {
                Task { await remotes.select(computer) }
            }
        } label: {
            row(icon: "desktopcomputer", title: computer.name, detail: detail(for: computer, isCurrent: isCurrent), isCurrent: isCurrent)
        }
        .swipeActions {
            if computer.isPaired {
                Button("Forget", role: .destructive) {
                    Task { await remotes.forget(computer) }
                }
            }
        }
    }

    private func detail(for computer: RemotePlayers.Computer, isCurrent: Bool) -> String {
        if isCurrent, let session = remotes.session {
            if remotes.playsFromAnotherServer { return "Signed in to a different server" }
            switch session.status {
            case .connecting: return "Connecting…"
            case .connected: return "Playing here"
            case .reconnecting: return "Reconnecting…"
            case .unreachable: return "Can’t reach it right now"
            }
        }
        if !computer.isPaired { return "Tap to pair" }
        return remotes.nearby.contains(computer.id) ? "Paired" : "Paired · not seen on this network"
    }

    private func row(icon: String, title: String, detail: String?, isCurrent: Bool) -> some View {
        HStack(spacing: Metrics.itemSpacing) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 32)
                .foregroundStyle(isCurrent ? Color.appTint : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isCurrent {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.appTint)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Settings → Remote Players.
struct RemotePlayersSettingsView: View {
    var body: some View {
        RemotePlayerList()
            .navigationTitle("Remote Players")
    }
}
