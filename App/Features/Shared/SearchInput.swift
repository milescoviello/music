import SwiftUI

extension View {
    /// For a search field: what goes in is a name -- an artist, an album, a song, a
    /// place -- which autocorrect "fixes" into some other word and the keyboard
    /// capitalises for nothing. Typing "zqxw" came out as "Zqxw".
    func searchInputAsTyped() -> some View {
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
}
