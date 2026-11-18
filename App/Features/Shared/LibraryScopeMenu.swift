import SwiftUI

/// The library switch: a menu whose label states the current scope, so there is no
/// need for a persistent banner or a segmented control eating a row.
///
/// Renders nothing at all when the server has one folder, which future-proofs
/// against a single-library server without a settings flag.
struct LibraryScopeMenu: View {
    @Environment(LibraryScopeStore.self) private var store

    var body: some View {
        if store.isSwitchable {
            Menu {
                Picker("Library", selection: Binding(
                    get: { store.scope },
                    set: { store.scope = $0 }
                )) {
                    ForEach(store.options, id: \.self) { option in
                        Text(option.shortName).tag(option)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "books.vertical")
                    if case .folder = store.scope {
                        Text(store.scope.shortName)
                            .font(.subheadline.weight(.medium))
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
            }
            // Without these VoiceOver read the symbols' names: "books.vertical, Go Down".
            .accessibilityLabel("Library")
            .accessibilityValue(store.scope.shortName)
        }
    }
}
