import SwiftUI
import UIKit

/// The row swipe a `List` gives, for rows that are not in one. "Can't swipe a song in the
/// artist page to queue" (2026-11-03): `.swipeActions` only works inside a `List`, and
/// Home and an artist's page are `ScrollView`s of mixed shelves.
///
/// Swipe right for the leading action, left for the trailing one, past the mark and let
/// go; a tick says when it will happen. The pan underneath only begins when the finger
/// moves mostly sideways, so scrolling up and down is left to the scroll view: a SwiftUI
/// `DragGesture` either holds the scroll back or runs along with it.
struct RowSwipe: ViewModifier {
    struct Action {
        let title: String
        let systemImage: String
        let tint: Color
        let perform: () -> Void
    }

    /// False in a `List`, which has its own.
    var isEnabled = true
    var leading: Action?
    var trailing: Action?

    @State private var offset: CGFloat = 0
    @State private var isArmed = false

    /// How far to swipe before letting go does it.
    private let mark: CGFloat = 76

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .offset(x: offset)
                .background(alignment: offset >= 0 ? .leading : .trailing) { revealed }
                .gesture(SidewaysPan(changed: moved, ended: released))
                .sensoryFeedback(.impact(weight: .medium), trigger: isArmed) { _, armed in armed }
        } else {
            content
        }
    }

    @ViewBuilder
    private var revealed: some View {
        if let action = offset > 0 ? leading : offset < 0 ? trailing : nil {
            ZStack(alignment: offset > 0 ? .leading : .trailing) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isArmed ? action.tint : action.tint.opacity(0.45))
                Label(action.title, systemImage: action.systemImage)
                    .labelStyle(.iconOnly)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
            }
            .frame(width: abs(offset))
            .accessibilityHidden(true)
        }
    }

    private func moved(_ translation: CGFloat) {
        // Only towards an edge that has an action; past the mark it drags heavier.
        var x = translation
        if x > 0, leading == nil { x = 0 }
        if x < 0, trailing == nil { x = 0 }
        let beyond = abs(x) - mark
        if beyond > 0 { x = (mark + beyond * 0.3) * (x < 0 ? -1 : 1) }
        offset = x
        isArmed = abs(x) >= mark
    }

    /// `completed` false when the system took the touch away: then nothing happens.
    private func released(completed: Bool) {
        let action = completed && isArmed ? (offset > 0 ? leading : trailing) : nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            offset = 0
        }
        isArmed = false
        action?.perform()
    }
}

/// A pan that begins only when the finger is moving mostly sideways.
private struct SidewaysPan: UIGestureRecognizerRepresentable {
    let changed: (CGFloat) -> Void
    let ended: (_ completed: Bool) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let x = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed:
            changed(x)
        case .ended:
            ended(true)
        case .cancelled, .failed:
            ended(false)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.5
        }
    }
}
