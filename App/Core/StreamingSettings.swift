import Foundation
import Observation

/// Plexamp's Quality and Caching settings, persisted. The decisions they drive are in
/// `StreamingPolicy`, which is tested; this only stores the choices and says when they
/// change.
@MainActor
@Observable
final class StreamingSettings {
    private static let key = "streaming.policy"

    var policy: StreamingPolicy {
        didSet {
            guard policy != oldValue else { return }
            if let data = try? JSONEncoder().encode(policy) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
            onChange?()
        }
    }

    /// The player re-plans its cache when any of these change.
    @ObservationIgnored var onChange: (() -> Void)?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode(StreamingPolicy.self, from: data) {
            policy = stored
        } else {
            policy = StreamingPolicy()
        }
    }
}
