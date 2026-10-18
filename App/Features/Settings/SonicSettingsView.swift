import SwiftUI

/// Where our sonic analysis service is, and how far through the library it has got.
struct SonicSettingsView: View {
    @Environment(SonicService.self) private var sonic

    @State private var address = ""
    @State private var token = ""
    @State private var isChecking = false

    var body: some View {
        Form {
            Section {
                if let status = sonic.status {
                    LabeledContent("Analysed", value: "\(status.analysed) of \(status.tracks)")
                    if status.analysed < status.tracks {
                        ProgressView(value: Double(status.analysed), total: Double(max(status.tracks, 1)))
                    }
                    LabeledContent("Now", value: status.analysing ? "Analysing new music" : "Up to date")
                    LabeledContent("Model", value: status.model)
                } else {
                    LabeledContent("Status", value: "Not connected")
                    if let error = sonic.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    Task {
                        isChecking = true
                        await sonic.refreshStatus(force: true)
                        isChecking = false
                    }
                } label: {
                    HStack {
                        Text("Check Now")
                        if isChecking { Spacer(); ProgressView() }
                    }
                }
            } header: {
                Text("Status")
            } footer: {
                Text("""
                Sonically Similar tracks, albums and artists, Sonic Adventure, the sonic \
                Guest DJs, track radio and mood stations come from this service, which \
                analyses every track the way Plex does. Until a track has been analysed, \
                those features use your server's similar songs instead.
                """)
            }

            Section {
                TextField("http://192.168.1.148:8650", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Token (optional)", text: $token)
                Button("Save") {
                    guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)), url.scheme != nil else { return }
                    sonic.configuration = SonicClient.Configuration(baseURL: url, token: token.isEmpty ? nil : token)
                }
                .disabled(URL(string: address.trimmingCharacters(in: .whitespaces))?.scheme == nil)
            } header: {
                Text("Service")
            }
        }
        .navigationTitle("Sonic Analysis")
        .onAppear {
            address = sonic.configuration.baseURL.absoluteString
            token = sonic.configuration.token ?? ""
        }
        .task { await sonic.refreshStatus(force: true) }
    }
}
