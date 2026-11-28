import ObjectiveC
import UIKit

/// Turns off the iPhone Duo's side bar for the whole app.
///
/// On the Duo's inner screen held sideways, iOS 27 gathers the status bar, the tab bar and
/// the navigation bar's buttons into one column down the side, by the camera. Here it took
/// a strip off every screen for chrome: the tabs stacked on their side, the screen's own
/// buttons beside them, and what was centred pushed off the middle of the glass. iOS 27.1
/// lets an app opt out, and then the tabs and buttons go back into ordinary bars and the
/// status bar back along the top.
///
/// The opt-out is a property a view controller overrides (`preferredVerticalBarBehavior`),
/// and SwiftUI has no modifier for it. Replacing `UIViewController`'s own answer was not
/// enough, measured in the Duo simulator: SwiftUI's hosting controllers answer for
/// themselves ("automatic"), and the root hands the question down to them. So three layers,
/// each harmless where another already worked:
/// 1. UIKit's own resolution, `_resolvedVerticalBarBehavior`, which windows and presentations
///    ask, answers "disabled" -- taken only when the method is there with the shape it is
///    known to have (an integer, no arguments).
/// 2. `UIViewController`'s public answer says the same.
/// 3. Every view controller class on screen that answers for itself is given the same answer
///    (`cover`), which is what reaches SwiftUI's hosting controllers.
/// Before iOS 27.1 there is nothing to turn off, and `EvenSideMargins` evens the column out
/// instead.
enum VerticalBar {
    private nonisolated(unsafe) static var answer: IMP?

    static func turnOff() {
        guard #available(iOS 27.1, *) else { return }
        let disabled = UIVerticalBarBehavior.disabled.rawValue
        let block: @convention(block) (AnyObject) -> Int = { _ in disabled }
        let imp = imp_implementationWithBlock(block)
        answer = imp
        let resolved = NSSelectorFromString("_resolvedVerticalBarBehavior")
        if let method = class_getInstanceMethod(UIViewController.self, resolved),
           let types = method_getTypeEncoding(method), String(cString: types).hasPrefix("q") {
            method_setImplementation(method, imp)
        }
        let getter = #selector(getter: UIViewController.preferredVerticalBarBehavior)
        if let method = class_getInstanceMethod(UIViewController.self, getter) {
            method_setImplementation(method, imp)
        }
    }

    /// Gives every view controller class under `root` that answers for itself the same answer,
    /// then has UIKit ask again. Cheap to repeat: a class already covered is passed over.
    @MainActor
    static func cover(_ root: UIViewController) {
        guard #available(iOS 27.1, *), let answer else { return }
        let getter = #selector(getter: UIViewController.preferredVerticalBarBehavior)
        var changed = false
        func visit(_ controller: UIViewController) {
            let cls: AnyClass = type(of: controller)
            if class_getMethodImplementation(cls, getter) != answer,
               let method = class_getInstanceMethod(cls, getter) {
                class_replaceMethod(cls, getter, answer, method_getTypeEncoding(method))
                changed = true
            }
            controller.children.forEach(visit)
            if let presented = controller.presentedViewController, presented.presentingViewController === controller {
                visit(presented)
            }
        }
        visit(root)
        if changed { root.setNeedsUpdateOfVerticalBarConfiguration() }
    }
}
