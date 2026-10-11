import SwiftUI

/// Plexamp's Playback settings: Loudness Leveling, Sweet Fades and the equaliser.
///
/// All three now apply to every track, streamed or downloaded — they run in the
/// processing tap inside the player rather than in a separate engine that could only
/// read local files — so the old "downloaded tracks only" switch and its caveat are gone.
/// Every control takes effect on the track already playing, within a fraction of a second.
struct AudioSettingsView: View {
    @Environment(AudioSettings.self) private var audio

    var body: some View {
        @Bindable var audio = audio

        Form {
            Section {
                Toggle("Loudness Leveling", isOn: $audio.loudnessLeveling)

                Picker("Preamp", selection: $audio.preamp) {
                    ForEach(LoudnessLeveling.preampOptions, id: \.self) { value in
                        Text(preampLabel(value)).tag(value)
                    }
                }
                .disabled(!audio.loudnessLeveling)

                Toggle("Limiter", isOn: $audio.limiter)
                    .disabled(!audio.loudnessLeveling)
            } header: {
                Text("Loudness Leveling")
            } footer: {
                Text("""
                Plays every track at a consistent volume, using the ReplayGain your \
                server reads from each file. The preamp is how far above the −18 LUFS \
                reference to aim; the limiter catches any peak that pushes past full \
                scale. Tracks with no gain data play as they are.
                """)
            }

            Section {
                Toggle("Sweet Fades", isOn: $audio.sweetFades)
            } footer: {
                Text("""
                Crossfades between tracks, for as long as each pair's intro and outro \
                allow — a long fade-out gets a long overlap, an abrupt ending almost none. \
                An album played in order is always gapless.
                """)
            }

            Section {
                NavigationLink(value: Destination.equalizer) {
                    LabeledContent("Equalizer", value: audio.equalizer ? audio.presetName : "Off")
                }
            } footer: {
                Text("Ten bands, with presets and your own saved curves.")
            }
        }
        .navigationTitle("Playback")
    }

    private func preampLabel(_ value: Double) -> String {
        let text = value > 0 ? "+\(Int(value)) dB" : "\(Int(value)) dB"
        return value == LoudnessLeveling.defaultPreamp ? "\(text) (Default)" : text
    }
}

/// Plexamp's equaliser screen. Its own screen, and deliberately not a scrolling one: ten
/// vertical faders inside a `Form` would fight the form's own vertical scroll, and every
/// attempt to scroll past them would move a band.
struct EqualizerView: View {
    @Environment(AudioSettings.self) private var audio

    @State private var isNamingPreset = false
    @State private var newPresetName = ""

    var body: some View {
        @Bindable var audio = audio

        VStack(alignment: .leading, spacing: 20) {
            Toggle("Equalizer", isOn: $audio.equalizer)
                .font(.headline)

            GraphicEqualizer(audio: audio)
                .opacity(audio.equalizer ? 1 : 0.35)
                .disabled(!audio.equalizer)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Preamp")
                    Spacer()
                    Text(gainLabel(audio.equalizerPreamp))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $audio.equalizerPreamp, in: -12...6, step: 0.5)
            }
            .disabled(!audio.equalizer)

            HStack(spacing: 12) {
                Menu {
                    ForEach(audio.allPresets) { preset in
                        Button {
                            audio.apply(preset)
                        } label: {
                            if audio.presetName == preset.name {
                                Label(preset.name, systemImage: "checkmark")
                            } else {
                                Text(preset.name)
                            }
                        }
                    }

                    if !audio.customPresets.isEmpty {
                        Divider()
                        Menu("Delete Saved Preset") {
                            ForEach(audio.customPresets) { preset in
                                Button(preset.name, role: .destructive) {
                                    audio.deleteCustom(preset)
                                }
                            }
                        }
                    }
                } label: {
                    Label(audio.presetName, systemImage: "slider.vertical.3")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Save…") {
                    newPresetName = ""
                    isNamingPreset = true
                }
                .disabled(audio.isFlat)

                Button("Flat") { audio.apply(.flat) }
                    .disabled(audio.isFlat)
            }
            .disabled(!audio.equalizer)

            Text("Double-tap a band to flatten it. A curve that boosts everywhere is better as a lower preamp.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(Metrics.gutter)
        .navigationTitle("Equalizer")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Save Preset", isPresented: $isNamingPreset) {
            TextField("Name", text: $newPresetName)
            Button("Save") { audio.saveCurrent(as: newPresetName) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func gainLabel(_ gain: Float) -> String {
        let text = String(format: "%.1f dB", gain)
        return gain > 0 ? "+\(text)" : text
    }
}

/// Ten vertical faders, the way a graphic EQ is drawn — so the curve is the shape on
/// screen rather than ten numbers in a list.
///
/// Hand-rolled rather than rotated `Slider`s: a rotated slider keeps its unrotated
/// layout size, which makes ten of them in a row impossible to lay out sensibly.
private struct GraphicEqualizer: View {
    let audio: AudioSettings

    private let height: CGFloat = 180

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(0..<Equalizer.bandCount, id: \.self) { index in
                VStack(spacing: 6) {
                    Text(shortGain(audio.bands[index]))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(abs(audio.bands[index]) < 0.01 ? .secondary : Color.appTint)

                    Fader(
                        value: audio.bands[index],
                        range: Equalizer.gainRange,
                        height: height,
                        onChange: { audio.setGain($0, forBand: index) }
                    )
                    .accessibilityLabel("\(Equalizer.labels[index]) hertz")
                    .accessibilityValue(shortGain(audio.bands[index]) + " decibels")
                    .accessibilityAdjustableAction { direction in
                        let step: Float = direction == .increment ? 0.5 : -0.5
                        audio.setGain(audio.bands[index] + step, forBand: index)
                    }

                    Text(Equalizer.labels[index])
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func shortGain(_ gain: Float) -> String {
        let rounded = (gain * 2).rounded() / 2
        if abs(rounded) < 0.01 { return "0" }
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return rounded > 0 ? "+\(text)" : text
    }
}

private struct Fader: View {
    let value: Float
    let range: ClosedRange<Float>
    let height: CGFloat
    let onChange: (Float) -> Void

    var body: some View {
        let span = range.upperBound - range.lowerBound
        let fraction = CGFloat((value - range.lowerBound) / span)
        let knobY = height * (1 - fraction)
        let centreY = height * CGFloat(range.upperBound / span)

        ZStack(alignment: .top) {
            Capsule()
                .fill(.quaternary)
                .frame(width: 4, height: height)

            // The fill runs from 0 dB to the knob, so boosts and cuts read differently.
            Capsule()
                .fill(Color.appTint)
                .frame(width: 4, height: abs(knobY - centreY))
                .offset(y: min(knobY, centreY))

            Circle()
                .fill(.white)
                .shadow(radius: 1, y: 1)
                .frame(width: 18, height: 18)
                .offset(y: knobY - 9)
        }
        .frame(width: 28, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let clamped = min(max(drag.location.y, 0), height)
                    let raw = range.upperBound - Float(clamped / height) * span
                    onChange((raw * 2).rounded() / 2)
                }
        )
        .onTapGesture(count: 2) { onChange(0) }
    }
}
