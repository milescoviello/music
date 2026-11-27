import SwiftUI

/// One place for the numbers, so screens line up without each view inventing its
/// own spacing. Values are chosen to match the system's own list insets on iPhone:
/// a `ScrollView` screen and a `List` screen share the same left edge.
enum Metrics {
    // Horizontal gutter. 16 matches List's inset on iPhone.
    static let gutter: CGFloat = 16

    // Vertical rhythm
    static let shelfSpacing: CGFloat = 28
    static let headerToContent: CGFloat = 12
    static let itemSpacing: CGFloat = 12

    /// Album grids: as many columns as fit covers at least 145 points across. Two on
    /// every iPhone, the same size the fixed two columns were (a 375-point screen with
    /// the A-Z rail still fits two); four on the iPhone Duo's unfolded 7.6" screen,
    /// where two would have made each cover over 300 points across.
    static let albumGrid = [GridItem(.adaptive(minimum: 145), spacing: itemSpacing)]

    // Corner radii, all .continuous
    static let radiusThumb: CGFloat = 6
    static let radiusCard: CGFloat = 8
    static let radiusHeader: CGFloat = 10
    static let radiusPlayer: CGFloat = 12

    // Artwork sizes
    static let thumbSmall: CGFloat = 40
    static let thumbRow: CGFloat = 48
    static let thumbPlaylist: CGFloat = 56
    static let cardWidth: CGFloat = 160
    static let detailArtwork: CGFloat = 200

    // Rows
    static let rowCategory: CGFloat = 44
    static let rowTrack: CGFloat = 44
    static let rowSong: CGFloat = 56
    static let miniPlayerHeight: CGFloat = 56

    // Touch
    static let minimumTouchTarget: CGFloat = 44
}

extension Color {
    /// The app's own pink: the accent before any song's colours are in.
    static let appPink = Color(red: 0.98, green: 0.28, blue: 0.36)

    /// The accent, which follows the playing song's cover as the Linux app's does
    /// (`CoverTint`). A view that reads it redraws when the song changes.
    static var appTint: Color { CoverTint.shared.accent ?? appPink }
}

/// Room at the bottom of a scrolling screen for the now-playing bar.
///
/// On iOS 26 the bar lives in `tabViewBottomAccessory`, and the system reserves space for
/// it — on a tab's *root*. It does not do so reliably on a pushed screen, which is why the
/// last song of a playlist was sitting underneath it. So pushed screens ask for the room
/// explicitly, and only when there is a bar to make room for: with no queue there is no
/// bar, and a permanent 64pt hole at the bottom of every list is its own bug.
///
/// `safeAreaPadding` rather than `padding`: it extends the scroll view's content inset, so
/// the list still scrolls under the bar rather than ending in a visible gap.
struct PlayerClearance: ViewModifier {
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content.safeAreaPadding(
            .bottom,
            appState.player.hasQueue ? Metrics.miniPlayerHeight + 8 : 0
        )
    }
}

extension View {
    /// Attach to the scrolling container of any screen that is *pushed* rather than a tab
    /// root. Harmless to attach twice; do not attach on tab roots, where the system
    /// already reserves the space.
    func playerClearance() -> some View {
        modifier(PlayerClearance())
    }
}

/// The same room on both sides, so what is centred sits in the middle of the glass.
///
/// The iPhone Duo's inner screen held sideways keeps the camera and the status bar in a
/// column down one side, and iOS marks only that side unsafe -- a notched iPhone on its
/// side is given the same inset on both. Centred in what was left, the player and
/// everything else centred sat some 40 pt left of the middle. Each side now gets the
/// larger of the two; where they already match, which is everywhere but there, this
/// adds nothing, so it is harmless to apply at more than one level.
///
/// `safeAreaPadding`, not `padding`, so backdrops that ignore the safe area still run edge
/// to edge and lists still scroll under the margin. The insets are read by a
/// `GeometryReader` of its own, outside the padding: measured on the padded content, the
/// reading would include its own correction and chase it.
struct EvenSideMargins: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let lopsided = proxy.safeAreaInsets.trailing - proxy.safeAreaInsets.leading
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaPadding(.leading, max(0, lopsided))
                .safeAreaPadding(.trailing, max(0, -lopsided))
        }
    }
}

extension View {
    /// See `EvenSideMargins`. On the app's root, on each tab (each is hosted by its own
    /// controller, which a modifier outside the `TabView` does not reach) and on the
    /// player.
    func evenSideMargins() -> some View {
        modifier(EvenSideMargins())
    }
}
