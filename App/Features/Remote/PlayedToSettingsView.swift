import SwiftUI

/// Whether a computer may play to this phone, what it sees the phone called, and which
/// are paired: the desktop's Remote Control page, the other way round.
struct PlayedToSettingsView: View {
    @State private var name = RemoteControlServer.shared.name

    private var server: RemoteControlServer { RemoteControlServer.shared }

    var body: some View {
        Form {
            Section {
                Toggle("Let Computers Play Here", isOn: Binding(
                    get: { server.isEnabled },
                    set: { server.isEnabled = $0 }
                ))
                if server.isEnabled {
                    TextField("Name", text: $name)
                        .onSubmit {
                            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty { server.name = String(trimmed.prefix(60)) }
                        }
                    LabeledContent("Address", value: address)
                        .textSelection(.enabled)
                    LabeledContent("Connected Now", value: connected)
                }
            } footer: {
                Text("Music on a computer can play to this iPhone, the way it plays here: in its player, choose Play On and this name. The first time, this iPhone shows a code to type in there. It listens only while Music is open or playing, and only to devices on this network.")
            }

            if server.isEnabled {
                Section("Paired Computers") {
                    if server.devices.isEmpty {
                        Text("None yet").foregroundStyle(.secondary)
                    }
                    ForEach(server.devices) { device in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text("Paired \(device.pairedAt.formatted(.relative(presentation: .named)))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Forget", role: .destructive) { server.forget(device) }
                        }
                    }
                }
            }
        }
        .navigationTitle("This iPhone")
    }

    private var address: String {
        guard let port = server.port else { return "Not listening" }
        let addresses = HTTPServer.localAddresses()
        return addresses.isEmpty ? "Port \(port)" : addresses.map { "\($0):\(port)" }.joined(separator: ", ")
    }

    private var connected: String {
        let count = server.listenerCount
        return count == 0 ? "None" : count == 1 ? "1 computer" : "\(count) computers"
    }
}

/// A computer asking to play here: the code to type in there, over whatever is open.
struct RemotePairingPrompt: ViewModifier {
    func body(content: Content) -> some View {
        let server = RemoteControlServer.shared
        let device = server.pairing?.device ?? "the computer"
        content.alert(
            "Pair with \(device)?",
            isPresented: Binding(get: { server.pairing != nil }, set: { if !$0 { server.cancelPairing() } })
        ) {
            Button("Don't Allow", role: .cancel) { server.cancelPairing() }
        } message: {
            Text("Type this code on \(device) to let it play here:\n\n\(Self.spaced(server.pairing?.code ?? ""))")
        }
    }

    static func spaced(_ code: String) -> String {
        code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
    }
}

extension View {
    func remotePairingPrompt() -> some View { modifier(RemotePairingPrompt()) }
}
