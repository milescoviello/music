import Foundation

/// The shared code's symbols (stations, Autoplay, repeat) by the phone's SF Symbol names,
/// drawn with their Phosphor twins (`Symbol`).
enum Icons {
    static func named(_ symbol: String) -> String {
        Symbol.icon(symbol)
    }
}
