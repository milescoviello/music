import CoreLocation
import MapKit
import Observation

/// Turn-by-turn for the car (`RemoteCarNavigator`): Apple Maps works out the route, and the
/// car (`RemoteControl`, "The car.") follows it on its own map. A route starts here (search,
/// or a recent place) or from the car's Destination page, which offers the recents.
@MainActor
@Observable
final class CarNavigation: NSObject, RemoteCarNavigator {
    static let shared = CarNavigation()

    /// One search result, as plain data.
    struct Hit: Identifiable, Sendable {
        var id: String { "\(lat),\(lon),\(name)" }
        var name: String
        var address: String
        var lat: Double
        var lon: Double
    }

    private(set) var route: RemoteCarRoute?
    private(set) var destination: RemoteCarPlace?
    private(set) var recents: [RemoteCarPlace] = []
    private(set) var isRouting = false
    private(set) var problem: String?

    @ObservationIgnored private let location = CLLocationManager()
    @ObservationIgnored private static let recentsKey = "carNavigation.recents"

    override init() {
        super.init()
        location.delegate = self
        if let data = UserDefaults.standard.data(forKey: Self.recentsKey),
           let saved = try? JSONDecoder().decode([RemoteCarPlace].self, from: data) {
            recents = saved
        }
    }

    // MARK: RemoteCarNavigator

    func places() -> RemoteCarPlaces {
        RemoteCarPlaces(items: recents.map { .init(id: $0.id, title: $0.title, subtitle: $0.subtitle) })
    }

    func navigate(toPlace id: String) async -> Bool {
        guard let place = recents.first(where: { $0.id == id }) else { return false }
        return await start(place)
    }

    func reroute(from: RemoteCarReroute) async {
        guard let place = destination else { return }
        guard let route = await Self.directions(from: CLLocationCoordinate2D(latitude: from.lat, longitude: from.lon),
                                                to: place, new: false) else { return }
        self.route = route
        RemoteControlServer.shared.publishRoute(route)
    }

    func stop() {
        route = nil
        destination = nil
        location.stopUpdatingLocation()
        RemoteControlServer.shared.publishRoute(nil)
    }

    // MARK: Here

    /// Asks once for "while using" location: Maps needs to know where the drive starts.
    func prepare() {
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        location.startUpdatingLocation()
    }

    func search(_ text: String) async -> [Hit] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return await Self.search(query, near: location.location?.coordinate)
    }

    func start(_ hit: Hit) async -> Bool {
        let id = String(format: "%.5f,%.5f", hit.lat, hit.lon)
        return await start(RemoteCarPlace(id: id, title: hit.name, subtitle: hit.address,
                                          lat: hit.lat, lon: hit.lon, usedAt: .now))
    }

    func start(_ place: RemoteCarPlace) async -> Bool {
        prepare()
        isRouting = true
        problem = nil
        defer { isRouting = false }
        var used = place
        used.usedAt = .now
        recents = RemoteCarPlace.remember(used, in: recents)
        if let data = try? JSONEncoder().encode(recents) { UserDefaults.standard.set(data, forKey: Self.recentsKey) }
        guard let route = await Self.directions(from: nil, to: used, new: true) else {
            problem = "Maps found no driving route to \(place.title)."
            return false
        }
        destination = used
        self.route = route
        RemoteControlServer.shared.publishRoute(route)
        return true
    }

    func forget(_ place: RemoteCarPlace) {
        recents.removeAll { $0.id == place.id }
        if let data = try? JSONEncoder().encode(recents) { UserDefaults.standard.set(data, forKey: Self.recentsKey) }
    }

    // MARK: Maps (it answers on the main thread; turned into plain data there)

    private static func search(_ query: String, near: CLLocationCoordinate2D?) async -> [Hit] {
        await withCheckedContinuation { (done: CheckedContinuation<[Hit], Never>) in
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            if let near {
                request.region = MKCoordinateRegion(center: near, latitudinalMeters: 100_000, longitudinalMeters: 100_000)
            }
            MKLocalSearch(request: request).start { response, _ in
                // read out as plain data right here; nothing of MapKit's leaves this closure
                let hits = (response?.mapItems ?? []).prefix(15).map { item -> Hit in
                    let mark = item.placemark
                    return Hit(name: item.name ?? mark.title ?? "Place", address: mark.title ?? "",
                               lat: mark.coordinate.latitude, lon: mark.coordinate.longitude)
                }
                done.resume(returning: Array(hits))
            }
        }
    }

    /// Driving directions to `place`, from `origin` (where the car says it is) or from here.
    private static func directions(from origin: CLLocationCoordinate2D?, to place: RemoteCarPlace,
                                   new: Bool) async -> RemoteCarRoute? {
        await withCheckedContinuation { (done: CheckedContinuation<RemoteCarRoute?, Never>) in
            let request = MKDirections.Request()
            request.source = origin.map { MKMapItem(placemark: MKPlacemark(coordinate: $0)) } ?? MKMapItem.forCurrentLocation()
            let to = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon)))
            to.name = place.title
            request.destination = to
            request.transportType = .automobile
            let title = place.title
            MKDirections(request: request).calculate { response, _ in
                // read out as plain data right here; nothing of MapKit's leaves this closure
                guard let best = response?.routes.first else { return done.resume(returning: nil) }
                let steps = best.steps.map { RemoteCarRoute.MapsStep(instruction: $0.instructions, points: coordinates($0.polyline)) }
                done.resume(returning: RemoteCarRoute.from(points: coordinates(best.polyline), steps: steps,
                                                           distance: best.distance, time: best.expectedTravelTime,
                                                           destination: title, new: new))
            }
        }
    }

    private nonisolated static func coordinates(_ line: MKPolyline) -> [[Double]] {
        var raw = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: line.pointCount)
        line.getCoordinates(&raw, range: NSRange(location: 0, length: line.pointCount))
        return raw.map { [$0.latitude, $0.longitude] }
    }
}

extension CarNavigation: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
