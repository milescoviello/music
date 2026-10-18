import SwiftUI

/// Plexamp's Experience settings: how the player looks and behaves, and the home screen.
struct ExperienceSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlayerSettings.self) private var playerSettings

    @AppStorage("home.layout") private var layoutData: Data?
    @AppStorage(VisualizerProgram.highQualityKey) private var highQualityVisualizers = false
    @State private var isEditingHome = false

    var body: some View {
        @Bindable var playerSettings = playerSettings

        Form {
            Section {
                Toggle("Show Full Player", isOn: $playerSettings.opensPlayerOnPlay)
                Picker("Seekbar Style", selection: $playerSettings.seekbarStyle) {
                    ForEach(PlayerSettings.SeekbarStyle.allCases) { Text($0.title).tag($0) }
                }
                Picker("Background", selection: $playerSettings.background) {
                    ForEach(PlayerSettings.Background.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Keep Screen On", isOn: Binding(
                    get: { appState.screenAwake.isEnabled },
                    set: { appState.screenAwake.isEnabled = $0 }
                ))
                Toggle("Higher Quality Visualizers", isOn: $highQualityVisualizers)
            } header: {
                Text("Player")
            } footer: {
                Text("""
                Show Full Player opens the player whenever something starts playing. The \
                Smooth and Bars seekbars draw the track's loudness once it is on the phone. \
                Keep Screen On stops the phone sleeping while the app is open. Higher \
                Quality Visualizers draws them at the screen's full resolution: higher \
                quality, but more expensive.
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
