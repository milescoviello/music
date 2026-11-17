import Foundation
import Observation

/// A value a page's observers re-run on, for state that lives only in the page (Edit on or
/// off): the phone's `@State`.
@MainActor
@Observable
final class Observed<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
