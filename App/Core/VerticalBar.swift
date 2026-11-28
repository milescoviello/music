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
/// and SwiftUI has no modifier for it. The root of a SwiftUI app is SwiftUI's own hosting
/// controller, which the app cannot subclass, so `UIViewController`'s own answer is
/// replaced, once, at launch. The tab and navigation controllers hand the question on to
/// the screen they show, and that screen, a sheet's included, answers through this.
/// Before iOS 27.1 there is nothing to turn off, and `EvenSideMargins` evens the column
/// out instead.
enum VerticalBar {
    static func turnOff() {
        guard #available(iOS 27.1, *) else { return }
        let getter = #selector(getter: UIViewController.preferredVerticalBarBehavior)
        guard let method = class_getInstanceMethod(UIViewController.self, getter) else { return }
        let disabled = UIVerticalBarBehavior.disabled.rawValue
        let answer: @convention(block) (AnyObject) -> Int = { _ in disabled }
        method_setImplementation(method, imp_implementationWithBlock(answer))
    }
}
