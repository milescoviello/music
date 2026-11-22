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
            SettingsLog.changedFields("Streaming", from: oldValue, to: policy)
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
        // Once: cellular caching less far ahead than the new default, as the old default of
        // five did, goes up to it. Never less on cellular (his call, 11-22).
        let raised = "streaming.cellularRaised.1"
        if !UserDefaults.standard.bool(forKey: raised) {
            UserDefaults.standard.set(true, forKey: raised)
            let floor = StreamingPolicy().cellularCacheAhead
            if policy.cellularCacheAhead < floor { policy.cellularCacheAhead = floor }
        }
    }
}
