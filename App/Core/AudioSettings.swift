import Foundation
import Observation

/// Plexamp's playback settings: Loudness Leveling, its preamp and limiter, Sweet Fades,
/// and the ten-band equaliser.
///
/// These used to come with a caveat — EQ and crossfade applied to downloaded tracks only,
/// because they ran in an `AVAudioEngine` that cannot stream. They now run in the
/// processing tap on every `AVPlayerItem`, so they apply to everything, and the caveat
/// and its on/off switch are gone.
///
/// Defaults are Plexamp's: leveling on at +4 dB with the limiter, Sweet Fades on, the
/// equaliser off.
/// Every change is pushed straight into `dsp`, which the tap of whatever is playing reads
/// within one buffer — moving a slider never reloads the track.
@MainActor
@Observable
final class AudioSettings {
    private enum Key {
        static let leveling = "audio.leveling"
        static let preamp = "audio.preamp"
        static let limiter = "audio.limiter"
        static let sweetFades = "audio.sweetFades"
        static let beatMatchedFades = "audio.beatMatchedFades"
        static let equalizer = "audio.eq.enabled"
        static let bands = "audio.eq.bands"
        static let equalizerPreamp = "audio.eq.preamp"
        static let preset = "audio.eq.preset"
        static let custom = "audio.eq.custom"

        // The five-band engine EQ this replaces. Read once, to carry a curve over.
        static let legacyEnabled = "audio.enhanced.enabled"
        static let legacyGains = "audio.eq.gains"
    }

    /// The live parameters every playing track's tap reads.
    let dsp = DSPSettingsStore()

    var loudnessLeveling: Bool {
        didSet { save(loudnessLeveling, Key.leveling) }
    }

    /// Decibels above the −18 LUFS reference. One of `LoudnessLeveling.preampOptions`.
    var preamp: Double {
        didSet { save(preamp, Key.preamp) }
    }

    var limiter: Bool {
        didSet { save(limiter, Key.limiter) }
    }

    /// Plexamp's smart crossfade: every transition fades except within an album played in
    /// order, for as long as the two tracks' own shapes allow.
    var sweetFades: Bool {
        didSet {
            UserDefaults.standard.set(sweetFades, forKey: Key.sweetFades)
            onTransitionsChange?()
        }
    }

    /// Sweet Fades that land the incoming track's beats on the outgoing one's, for pairs
    /// whose tempos allow it — see `BeatMatch`. Off unless asked for, and only ever on top
    /// of Sweet Fades: with that off, this does nothing.
    var beatMatchedFades: Bool {
        didSet {
            UserDefaults.standard.set(beatMatchedFades, forKey: Key.beatMatchedFades)
            onTransitionsChange?()
        }
    }

    /// Fired when a setting changes how transitions sound, so the player can re-plan the
    /// ones it has already lined up. Leveling and the EQ need no such call: the tap of
    /// whatever is playing reads them live.
    var onTransitionsChange: (() -> Void)?

    var equalizer: Bool {
        didSet { save(equalizer, Key.equalizer) }
    }

    /// Decibels, one per `Equalizer.frequencies` band.
    private(set) var bands: [Float] {
        didSet { save(bands, Key.bands) }
    }

    var equalizerPreamp: Float {
        didSet { save(equalizerPreamp, Key.equalizerPreamp) }
    }

    private(set) var presetName: String {
        didSet { UserDefaults.standard.set(presetName, forKey: Key.preset) }
    }

    /// Curves the user saved under their own names.
    private(set) var customPresets: [Preset] {
        didSet {
            let encoded = try? JSONEncoder().encode(customPresets)
            UserDefaults.standard.set(encoded, forKey: Key.custom)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        loudnessLeveling = defaults.object(forKey: Key.leveling) as? Bool ?? true
        preamp = defaults.object(forKey: Key.preamp) as? Double ?? LoudnessLeveling.defaultPreamp
        limiter = defaults.object(forKey: Key.limiter) as? Bool ?? true
        sweetFades = defaults.object(forKey: Key.sweetFades) as? Bool ?? true
        beatMatchedFades = defaults.bool(forKey: Key.beatMatchedFades)
        equalizerPreamp = defaults.object(forKey: Key.equalizerPreamp) as? Float ?? 0
        presetName = defaults.string(forKey: Key.preset) ?? Preset.flat.name

        if let data = defaults.data(forKey: Key.custom),
           let stored = try? JSONDecoder().decode([Preset].self, from: data) {
            customPresets = stored
        } else {
            customPresets = []
        }

        if let stored = defaults.array(forKey: Key.bands) as? [Float],
           stored.count == Equalizer.bandCount {
            bands = stored
            equalizer = defaults.bool(forKey: Key.equalizer)
        } else if let legacy = defaults.array(forKey: Key.legacyGains) as? [Float] {
            // The old five bands, interpolated onto the new ten, and switched on only if
            // the old EQ was both on and actually shaping something.
            let carried = Equalizer.resample(legacy, from: [60, 250, 1_000, 4_000, 12_000])
            bands = carried
            equalizer = defaults.bool(forKey: Key.legacyEnabled) && carried.contains { abs($0) > 0.01 }
            presetName = Preset.match(carried, among: Preset.builtIn)?.name ?? Preset.custom
        } else {
            bands = Array(repeating: 0, count: Equalizer.bandCount)
            equalizer = defaults.bool(forKey: Key.equalizer)
        }

        publish()
    }

    // MARK: - Equaliser

    var isFlat: Bool {
        bands.allSatisfy { abs($0) < 0.01 }
    }

    var allPresets: [Preset] { Preset.builtIn + customPresets }

    func setGain(_ value: Float, forBand index: Int) {
        guard bands.indices.contains(index) else { return }
        bands[index] = min(max(value, Equalizer.gainRange.lowerBound), Equalizer.gainRange.upperBound)
        // Any hand adjustment stops claiming to be a named preset.
        presetName = Preset.match(bands, among: allPresets)?.name ?? Preset.custom
        publish()
    }

    func apply(_ preset: Preset) {
        bands = preset.gains
        presetName = preset.name
        publish()
    }

    /// Saves the current curve under `name`, replacing a custom preset of the same name.
    func saveCurrent(as name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !Preset.builtIn.contains(where: { $0.name == trimmed }) else { return }
        customPresets.removeAll { $0.name == trimmed }
        customPresets.append(Preset(name: trimmed, gains: bands))
        presetName = trimmed
    }

    func deleteCustom(_ preset: Preset) {
        customPresets.removeAll { $0.name == preset.name }
        if presetName == preset.name { presetName = Preset.custom }
    }

    // MARK: - Publishing

    /// Pushes everything into the store the audio thread reads. Called after any change;
    /// cheap, and coalescing it would only add a way for the two to disagree.
    func publish() {
        let leveling = loudnessLeveling
        let preamp = preamp
        let limiter = limiter
        let equalizer = equalizer
        let equalizerPreamp = equalizerPreamp
        var lanes = SIMD16<Float>(repeating: 0)
        for (index, gain) in bands.enumerated() where index < 16 { lanes[index] = gain }

        dsp.update { parameters in
            parameters.loudnessLeveling = leveling
            parameters.preamp = preamp
            parameters.limiter = limiter
            parameters.equalizer = equalizer
            parameters.bands = lanes
            parameters.equalizerPreamp = equalizerPreamp
        }
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
        publish()
    }

    // MARK: - Presets

    struct Preset: Codable, Identifiable, Hashable, Sendable {
        let name: String
        let gains: [Float]

        var id: String { name }

        static let custom = "Custom"

        static let flat = Preset(name: "Flat", gains: Array(repeating: 0, count: Equalizer.bandCount))

        /// Gentle on purpose. Heavy-handed presets clip on loud masters; the limiter
        /// catches that, but a curve that never needs it sounds better.
        static let builtIn: [Preset] = [
            flat,
            Preset(name: "Bass Boost", gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
            Preset(name: "Bass Reduce", gains: [-5, -4, -3, -1, 0, 0, 0, 0, 0, 0]),
            Preset(name: "Treble Boost", gains: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
            Preset(name: "Vocal", gains: [-2, -2, -1, 0, 2, 3, 4, 3, 1, 0]),
            Preset(name: "Loudness", gains: [5, 4, 2, 0, -1, -1, 0, 2, 3, 4]),
            Preset(name: "Warm", gains: [3, 3, 2, 1, 0, 0, -1, -2, -3, -3]),
            Preset(name: "Late Night", gains: [-3, -2, -1, 0, 1, 2, 2, 1, 0, -1]),
        ]

        static func match(_ gains: [Float], among presets: [Preset]) -> Preset? {
            presets.first { preset in
                preset.gains.count == gains.count
                    && zip(preset.gains, gains).allSatisfy { abs($0 - $1) < 0.01 }
            }
        }
    }
}
