import Foundation

/// The container the app and its widgets share: an App Group the signing profile allows.
///
/// Its name is not this project's to choose -- the phone signs the app with a profile that
/// lists the groups it may use -- so it is read from that profile, embedded in the app and
/// in the widget extension alike. Nil when the profile allows none, and the widgets then
/// say to open the app.
enum AppGroup {
    static let identifier: String? = {
        let bundle = Bundle.main.bundleURL
        // The extension's own profile, or the app's two folders up (Music.app/PlugIns/x.appex).
        let candidates = [
            bundle.appendingPathComponent("embedded.mobileprovision"),
            bundle.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("embedded.mobileprovision"),
        ]
        for url in candidates {
            guard let groups = applicationGroups(in: url), let first = groups.first(where: { !$0.contains("*") }) else { continue }
            return first
        }
        return nil
    }()

    static var container: URL? {
        identifier.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    /// The groups a provisioning profile allows, from the plist inside its signature.
    static func applicationGroups(in url: URL) -> [String]? {
        guard let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any]
        else { return nil }
        return entitlements["com.apple.security.application-groups"] as? [String]
    }
}
