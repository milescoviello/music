import Foundation
import Observation

/// The last few things searched for.
///
/// Recorded on submit and when a result is tapped — **never** per keystroke. `SearchView`
/// searches from a debounced `.task(id:)`, so recording there would store "l", "le",
/// "let" and bury the one search that mattered.
@MainActor
@Observable
final class RecentSearches {
    private(set) var terms: [String] = []

    private let key = "search.recent"
    private let limit = 8

    init() {
        terms = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func record(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Case-insensitive de-dupe, most recent first: searching the same thing twice
        // should move it up, not appear twice.
        terms.removeAll { $0.compare(trimmed, options: .caseInsensitive) == .orderedSame }
        terms.insert(trimmed, at: 0)
        terms = Array(terms.prefix(limit))
        UserDefaults.standard.set(terms, forKey: key)
    }

    func clear() {
        terms = []
        UserDefaults.standard.removeObject(forKey: key)
    }
}
