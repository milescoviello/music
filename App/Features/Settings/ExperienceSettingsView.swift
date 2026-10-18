import SwiftUI

/// Plexamp's Experience settings: how the player looks and behaves, and the home screen.
struct ExperienceSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlayerSettings.self) private var playerSettings

    @AppStorage("home.layout") private var layoutData: Data?
    @State private var isEditingHome = false

    var body: some View {
        @Bindable var playerSettings = playerSettings

        Form {
            Section {
                Toggle("Show Full Player", isOn: $playerSettings.opensPlayerOnPlay)
                Toggle("Keep Screen On", isOn: Binding(
                    get: { appState.screenAwake.isEnabled },
                    set: { appState.screenAwake.isEnabled = $0 }
                ))
            } header: {
                Text("Player")
            } footer: {
                Text("""
                Show Full Player opens the player whenever something starts playing. Keep \
                Screen On stops the phone sleeping while the app is open — for lyrics on a \
                desk, or a long mix.
                """)
            }

            Section {
                Toggle("Music Quick Skip", isOn: $playerSettings.showsSkipButtons)
                Picker("Skip Backwards", selection: $playerSettings.skipBackSeconds) {
                    ForEach(PlayerSettings.skipOptions, id: \.self) { Text("\($0) sec").tag($0) }
                }
                .disabled(!playerSettings.showsSkipButtons)
                Picker("Skip Forwards", selection: $playerSettings.skipForwardSeconds) {
                    ForEach(PlayerSettings.skipOptions, id: \.self) { Text("\($0) sec").tag($0) }
                }
                .disabled(!playerSettings.showsSkipButtons)
            } header: {
                Text("Quick Skip")
            } footer: {
                Text("""
                Buttons either side of the transport that jump within the track — for mixes, \
                live sets and anything long. Playback speed is in the player's menu.
                """)
            }

            Section {
                Button("Edit Home Screen…") { isEditingHome = true }
                Button("Reset Home Screen", role: .destructive) { layoutData = nil }
                    .disabled(layoutData == nil)
            } header: {
                Text("Home Screen")
            } footer: {
                Text("Choose which shelves Home shows, and in what order.")
            }
        }
        .navigationTitle("Experience")
        .sheet(isPresented: $isEditingHome) {
            HomeEditorView(layoutData: $layoutData)
        }
    }
}
