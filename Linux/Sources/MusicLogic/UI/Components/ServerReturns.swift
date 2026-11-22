import Foundation

extension Widget {
    /// Runs `reload` each time the server answers again after a silence
    /// (`AppState.serverReturns`): a page that showed its saved copy meanwhile shows the
    /// server's, rather than keeping the saved one until it is opened again.
    @discardableResult
    func reloadsWhenServerReturns(_ app: AppState, _ reload: @escaping @MainActor () -> Void) -> Self {
        let seen = ServerReturnCount(app.serverReturns)
        return observe {
            let returns = app.serverReturns
            guard returns != seen.value else { return }
            seen.value = returns
            reload()
        }
    }
}

@MainActor
private final class ServerReturnCount {
    var value: Int
    init(_ value: Int) { self.value = value }
}
