import Foundation

/// When the overnight sync (`OvernightSync`) asks iOS to run it next: one in the morning,
/// tonight's if that is still to come, else tomorrow's. iOS picks the moment after that, once
/// the phone is on a charger with a network.
enum OvernightWindow {
    static let hour = 1

    static func next(after now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(86_400)
    }
}
