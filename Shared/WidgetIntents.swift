import AppIntents
import Foundation

/// What the widgets' buttons do, in the app: the widgets cannot reach the player, which
/// lives in the app's process. Audio intents are run there by the system, the app started
/// in the background if it is not running, and the app hands its player to `handler`.
@MainActor
enum WidgetControl {
    enum Action: Sendable {
        case toggle, next, previous
        case mix(Int)
    }

    static var handler: (@MainActor (Action) async -> Void)?

    static func run(_ action: Action) async {
        // An app started just for this sets its handler a moment after launching.
        for _ in 0..<20 where handler == nil {
            try? await Task.sleep(for: .milliseconds(150))
        }
        await handler?(action)
    }
}

struct TogglePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await WidgetControl.run(.toggle)
        return .result()
    }
}

struct NextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Song"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await WidgetControl.run(.next)
        return .result()
    }
}

struct PreviousTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Song"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await WidgetControl.run(.previous)
        return .result()
    }
}

/// One of the Made for You widget's mixes: opens the app, which plays it.
struct PlayWidgetMixIntent: AppIntent {
    static let title: LocalizedStringResource = "Play a Mix"
    static let isDiscoverable = false
    static let openAppWhenRun = true

    @Parameter(title: "Mix")
    var number: Int

    init() {}

    init(number: Int) {
        self.number = number
    }

    func perform() async throws -> some IntentResult {
        await WidgetControl.run(.mix(number))
        return .result()
    }
}
