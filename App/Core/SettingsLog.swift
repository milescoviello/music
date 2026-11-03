import Foundation

/// Setting changes in the log, as "name: from → to", so a report can be read against what
/// was set at the time. A Made for You library switched one morning looked, in the log,
/// exactly like a bug that put both libraries back.
///
/// A slider sends a change for every step it is dragged through, so a setting is written
/// once it has been left alone for a moment, from where it started to where it ended, and
/// not at all if it ended where it started.
@MainActor
enum SettingsLog {
    private static var pending: [String: (from: String, to: String)] = [:]
    private static var flushTask: Task<Void, Never>?

    static func changed(_ name: String, from old: String, to new: String) {
        pending[name] = (pending[name]?.from ?? old, new)
        flushTask?.cancel()
        flushTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    static func changed(_ name: String, from old: Bool, to new: Bool) {
        changed(name, from: old ? "on" : "off", to: new ? "on" : "off")
    }

    static func changed(_ name: String, from old: some CustomStringConvertible, to new: some CustomStringConvertible) {
        changed(name, from: old.description, to: new.description)
    }

    /// Each stored field of a settings struct that differs, by its name: for the
    /// streaming policy, which is saved as one value.
    static func changedFields<Value>(_ prefix: String, from old: Value, to new: Value) {
        let before = Dictionary(
            Mirror(reflecting: old).children.compactMap { child in child.label.map { ($0, "\(child.value)") } },
            uniquingKeysWith: { first, _ in first }
        )
        for child in Mirror(reflecting: new).children {
            guard let label = child.label, let was = before[label] else { continue }
            let now = "\(child.value)"
            if was != now { changed("\(prefix) \(label)", from: was, to: now) }
        }
    }

    private static func flush() {
        let changes = pending.filter { $0.value.from != $0.value.to }.sorted { $0.key < $1.key }
        pending = [:]
        guard !changes.isEmpty else { return }
        let lines = changes.map { "\($0.key): \($0.value.from) → \($0.value.to)" }
        Task {
            for line in lines { await Diagnostics.shared.record("settings", line) }
        }
    }
}
