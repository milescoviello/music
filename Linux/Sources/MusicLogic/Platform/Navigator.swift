import Foundation
import Observation

/// Opening something from outside the page that shows it.
///
/// The phone's reason applies unchanged: the player is a layer over the whole app, and a
/// jump out of it — "Go to Album" — closes it and opens the destination in Library, where
/// albums and artists live and the way back is ordinary navigation. The phone pushes onto
/// a `NavigationPath`; here the window takes each request and pushes a page, so a request
/// is a queue rather than a path.
@MainActor
@Observable
final class Navigator {
    /// Whether the full-window player is up.
    var showsPlayer = false

    /// Destinations asked for and not yet opened, oldest first.
    private(set) var requests: [Destination] = []

    /// Set when a jump wants the Library tab selected. Read once by the window.
    private(set) var wantsLibraryTab = false

    /// Closes the player and opens `destination` in the Library tab.
    func open(_ destination: Destination) {
        showsPlayer = false
        wantsLibraryTab = true
        requests.append(destination)
    }

    /// Hands the window everything asked for since it last looked.
    func takeRequests() -> [Destination] {
        defer { requests = [] }
        return requests
    }

    func didSelectLibraryTab() {
        wantsLibraryTab = false
    }
}
