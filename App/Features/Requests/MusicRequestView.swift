import SwiftUI

/// Ask for music the library does not have.
///
/// The request goes to the Hermes agent, which searches Soulseek and acquires it.
///
/// The agent reports on its own channel, which this app cannot read. So rather than
/// claiming to track a transfer it cannot see, this screen watches the *library* and
/// says when the music actually turns up — an answer that cannot silently fail the
/// way a delivery hop can.
struct MusicRequestView: View {
    @Environment(MusicRequestService.self) private var requests

    /// Prefilled when arriving from a search that found nothing.
    var initialText: String = ""

    @State private var text = ""
    @State private var didSend = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Form {
            Group {
                if requests.isConfigured {
                    Section {
                        TextField("Artist — Album", text: $text, axis: .vertical)
                            .lineLimit(1...3)
                            .focused($isFocused)
                            .submitLabel(.send)
                            .onSubmit(send)

                        Button {
                            send()
                        } label: {
                            HStack {
                                Text("Send Request")
                                Spacer()
                                if requests.isSending { ProgressView() }
                            }
                        }
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || requests.isSending)
                    } header: {
                        Text("What do you want?")
                    } footer: {
                        if let error = requests.lastError {
                            Text(error).foregroundStyle(.red)
                        } else if didSend {
                            Text("Sent. This screen will say when it shows up in your library.")
                                .foregroundStyle(Color.appTint)
                        } else {
                            Text("An artist and album is enough. Hermes checks the library first so it will not fetch something you already have.")
                        }
                    }

                    if !requests.history.isEmpty {
                        Section {
                            ForEach(requests.history) { entry in
                                RequestRow(entry: entry)
                            }
                        } header: {
                            HStack {
                                Text("Requests")
                                Spacer()
                                if requests.isWatchingAnything {
                                    Text("checking your library")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .textCase(nil)
                                }
                            }
                        } footer: {
                            Text("The agent replies on its own channel, which this app cannot read — so instead it watches your library and tells you when the music actually turns up.")
                        }

                        Section {
                            Button("Clear History", role: .destructive) {
                                requests.clearHistory()
                            }
                        }
                    }
                } else {
                    Section {
                        ContentUnavailableView(
                            "Not Set Up",
                            systemImage: "antenna.radiowaves.left.and.right.slash",
                            description: Text(
                                "Add the Hermes webhook address and secret in Settings to request music from here."
                            )
                        )
                    }
                }
            }
            .glassRow()
        }
        .navigationTitle("Request Music")
        .refreshable { await requests.refresh() }
        .onAppear {
            if text.isEmpty { text = initialText }
            isFocused = requests.isConfigured && text.isEmpty
        }
        // Polls while the screen is open, and only while something is outstanding. A
        // request takes minutes to hours, so 20 s is attentive without being wasteful,
        // and the loop ends the moment everything has resolved.
        .task {
            while !Task.isCancelled, requests.isWatchingAnything {
                await requests.refresh()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    private func send() {
        let outgoing = text
        Task {
            if await requests.send(outgoing) {
                didSend = true
                text = ""
            }
        }
    }
}

/// One request, and what has become of it.
private struct RequestRow: View {
    let entry: MusicRequestService.Entry

    var body: some View {
        if let arrival = entry.arrival, let albumID = arrival.firstAlbumID {
            // Arrived and identifiable: make it a way into the music.
            NavigationLink(value: Destination.album(
                AlbumRef(id: albumID, name: arrival.albumNames.first ?? entry.text)
            )) {
                content
            }
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: Metrics.itemSpacing) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text).lineLimit(2)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(entry.arrival != nil ? Color.appTint : .secondary)
            }
        }
    }

    private var symbol: String {
        if entry.arrival != nil { return "checkmark.circle.fill" }
        if entry.gaveUp == true { return "questionmark.circle" }
        if !entry.wasAccepted { return "exclamationmark.triangle.fill" }
        return "clock"
    }

    private var tint: Color {
        if entry.arrival != nil { return .appTint }
        if !entry.wasAccepted { return .orange }
        return .secondary
    }

    /// Deliberately concrete about which of the four states this is. "Sent" on its own
    /// was the thing that made the old screen useless.
    private var status: String {
        if let arrival = entry.arrival {
            let names = arrival.albumNames.filter { !$0.isEmpty }
            if !names.isEmpty {
                return "Arrived — " + names.joined(separator: ", ")
            }
            let unit = arrival.songCount == 1 ? "track" : "tracks"
            return "Arrived — \(arrival.songCount) new " + unit
        }

        if !entry.wasAccepted {
            return "Not sent — " + entry.sentAt.formatted(date: .abbreviated, time: .shortened)
        }

        if entry.gaveUp == true {
            return "Never turned up. Sent " + entry.sentAt.formatted(date: .abbreviated, time: .omitted) + "."
        }

        return "Waiting since " + entry.sentAt.formatted(date: .omitted, time: .shortened)
    }
}

/// The webhook setup, in Settings. Separate from the request screen because it is
/// configured once and then never looked at again.
struct MusicRequestSettingsView: View {
    @Environment(MusicRequestService.self) private var requests

    @State private var address = ""
    @State private var secret = ""
    /// Where answers are read from. Not a secret — it is a LAN address serving read-only
    /// files — but kept out of the binary so a moved port needs no rebuild.
    @State private var resultsAddress = ""
    @State private var problem: String?
    @State private var isTesting = false
    @State private var testResult: String?

    var body: some View {
        Form {
            Group {
                Section {
                    TextField("http://192.168.1.148:8644/webhooks/music-request", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    SecureField("HMAC secret", text: $secret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("http://192.168.1.148:8645", text: $resultsAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    Button {
                        test()
                    } label: {
                        HStack {
                            Text("Test Results Address")
                            Spacer()
                            if isTesting {
                                ProgressView()
                            } else if let testResult {
                                Text(testResult)
                                    .font(.footnote)
                                    .foregroundStyle(testResult == "OK" ? .green : .red)
                            }
                        }
                    }
                    .disabled(resultsAddress.isEmpty || isTesting)
                } header: {
                    Text("Hermes Webhook")
                } footer: {
                    if let problem {
                        Text(problem).foregroundStyle(.red)
                    } else {
                        Text("""
                        The secret is kept in the Keychain on this phone. Requests are signed \
                        with it, and the gateway rejects anything unsigned or older than five \
                        minutes. The results address is where Hermes's answers are read from — \
                        the webhook itself is one-way.
                        """)
                    }
                }

                Section {
                    Button("Save") { save() }
                        .disabled(address.isEmpty || secret.isEmpty)

                    if requests.isConfigured {
                        Button("Remove", role: .destructive) {
                            requests.forget()
                            address = ""
                            secret = ""
                        }
                    }
                }
            }
            .glassRow()
        }
        .navigationTitle("Music Requests")
        .onAppear {
            if let configuration = requests.configuration {
                address = configuration.endpoint.absoluteString
                resultsAddress = configuration.resultsBase?.absoluteString ?? ""
                // The secret is never shown back: it is write-only from here, which is
                // what a secret field should be.
                secret = ""
            }
        }
    }

    private func save() {
        guard let url = URL(string: address), url.scheme != nil, url.host != nil else {
            problem = "That does not look like a URL."
            return
        }

        var results: URL?
        if !resultsAddress.isEmpty {
            guard let parsed = URL(string: resultsAddress), parsed.scheme != nil, parsed.host != nil
            else {
                problem = "The results address does not look like a URL."
                return
            }
            results = parsed
        }

        problem = nil
        requests.configure(endpoint: url, secret: secret, resultsBase: results)
    }

    /// Proves the read leg on its own, before any feature depends on it. The mailbox
    /// serves a fixed `ping.json` for exactly this.
    private func test() {
        guard let parsed = URL(string: resultsAddress), parsed.host != nil else {
            testResult = "Bad URL"
            return
        }
        isTesting = true
        testResult = nil
        Task {
            let client = HermesClient(
                configuration: .init(
                    endpoint: parsed, secret: secret, resultsBase: parsed
                )
            )
            testResult = await client.ping() ? "OK" : "No answer"
            isTesting = false
        }
    }
}
