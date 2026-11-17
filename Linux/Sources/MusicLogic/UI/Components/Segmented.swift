import CGtk
import Foundation

/// The phone's segmented picker (`.pickerStyle(.segmented)`): a grey capsule of choices,
/// the chosen one on a lighter pill. Search's Library | YouTube and its library scopes.
@MainActor
final class Segmented {
    let root: Box
    private var buttons: [(key: String, button: ToggleButton)] = []

    init(_ options: [(key: String, title: String)], selected: String, onChange: @escaping @MainActor (String) -> Void) {
        root = Box.horizontal(spacing: 0).homogeneous().css("segmented")
        var first: ToggleButton?
        for option in options {
            let button = ToggleButton(option.title, "segment") { on in
                if on { onChange(option.key) }
            }
            if let first { button.group(with: first) } else { first = button }
            buttons.append((option.key, button))
            root.append(button)
        }
        select(selected)
        root.keep(self)
    }

    /// Shows `key` as chosen without calling back.
    func select(_ key: String) {
        for entry in buttons { entry.button.isActive = entry.key == key }
    }
}
