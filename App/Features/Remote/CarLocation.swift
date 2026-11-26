import CoreLocation
import Observation

/// Sends this iPhone's position to the car (`RemoteCarLocating`). The car's own GPS receiver
/// belongs to its factory navigation, so its map and trip recorder run on the phone's fix,
/// sent about once a second while a car follows (`RemoteControlServer.publishLocation`).
///
/// Location runs only while a car is connected. The phone is usually in a pocket with the app
/// in the background by then, and only "Always" lets an app start location from the
/// background; with "While Using" it starts whenever the app is opened with the car connected.
@MainActor
@Observable
final class CarLocation: NSObject, RemoteCarLocating {
    static let shared = CarLocation()

    /// Off: the car runs on its own receiver only (which today means no position).
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            enabled ? start() : stop()
        }
    }
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var running = false
    private(set) var cars = 0
    private(set) var lastSent: Date?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var pacer = RemoteCarLocationPacer()
    /// Stops location a while after the last car leaves, not at once: the car's event stream
    /// reconnects after a quiet spell, and with "While Using" an app in the background can't
    /// start location again.
    @ObservationIgnored private var pendingStop: Task<Void, Never>?
    @ObservationIgnored private static let grace: Duration = .seconds(60)
    @ObservationIgnored private static let enabledKey = "carLocation.enabled"

    override init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        super.init()
        authorization = manager.authorizationStatus
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    // MARK: RemoteCarLocating

    func followersChanged(_ count: Int) {
        cars = count
        pendingStop?.cancel()
        pendingStop = nil
        if count > 0 {
            start()
        } else if running {
            pendingStop = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.grace)
                guard !Task.isCancelled, let self, self.cars == 0 else { return }
                self.stop()
            }
        }
    }

    // MARK: Permission

    /// "While Using" first; asked from Settings, where the app is open to show the prompt.
    func askPermission() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
    }

    // MARK: Running

    private func start() {
        guard enabled, cars > 0, !running else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()   // starts once answered (below)
        case .authorizedWhenInUse, .authorizedAlways:
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            pacer.reset()
            manager.startUpdatingLocation()
            running = true
        default:
            break
        }
    }

    private func stop() {
        guard running else { return }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        running = false
    }

    fileprivate func send(_ fix: RemoteCarLocation, at uptime: TimeInterval) {
        guard running, fix.usable, pacer.shouldSend(at: uptime) else { return }
        RemoteControlServer.shared.publishLocation(fix)
        lastSent = Date()
    }

    fileprivate func authorizationChanged() {
        authorization = manager.authorizationStatus
        if running, authorization != .authorizedAlways, authorization != .authorizedWhenInUse {
            stop()
        } else {
            start()
        }
    }
}

extension RemoteCarLocation {
    /// The car's shape of a Core Location fix. Unknown speed and course come as negatives,
    /// which is what the car expects too.
    init(_ location: CLLocation) {
        self.init(lat: location.coordinate.latitude,
                  lon: location.coordinate.longitude,
                  alt: location.verticalAccuracy >= 0 ? location.altitude : nil,
                  speed: location.speed >= 0 ? location.speed : -1,
                  course: location.course >= 0 ? location.course : -1,
                  acc: location.horizontalAccuracy,
                  t: location.timestamp.timeIntervalSince1970)
    }
}

extension CarLocation: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let fix = RemoteCarLocation(last)
        let uptime = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in CarLocation.shared.send(fix, at: uptime) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in CarLocation.shared.authorizationChanged() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
