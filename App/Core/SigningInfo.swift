import Foundation

/// How the installed app is signed, for the log: its bundle id, and what the provisioning
/// profile embedded in it says -- the app id, the team, when it runs out.
///
/// For a report that tapping the player on the lock screen or in the Dynamic Island did
/// nothing at all. Those open the app by the identity the system recorded for whoever is
/// playing, and a signing tool that re-signs an app under another identity, or leaves an
/// older copy installed beside it, sends that tap somewhere else. This says which identity
/// this copy has. On the desktop there is no profile, and it says so.
enum SigningInfo {
    static var summary: String {
        let bundle = Bundle.main.bundleIdentifier ?? "none"
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let profile = profile(at: url)
        else { return "bundle \(bundle), no embedded profile" }
        let entitlements = profile["Entitlements"] as? [String: Any] ?? [:]
        let appID = entitlements["application-identifier"] as? String ?? "?"
        let team = (profile["TeamIdentifier"] as? [String])?.first ?? "?"
        let name = profile["Name"] as? String ?? "?"
        let expires = (profile["ExpirationDate"] as? Date).map { ISO8601DateFormatter().string(from: $0) } ?? "?"
        return "bundle \(bundle), app id \(appID), team \(team), profile \"\(name)\" until \(expires); "
            + "can: \(capabilities(entitlements))"
    }

    /// What the profile lets the app do, by its entitlements' names, less the ones every
    /// profile has: whether App Groups (for widgets), Siri or push are among them decides
    /// what the app can have.
    static func capabilities(_ entitlements: [String: Any]) -> String {
        let everyone: Set<String> = [
            "application-identifier", "com.apple.developer.team-identifier", "keychain-access-groups", "get-task-allow",
        ]
        let names = entitlements.keys
            .filter { !everyone.contains($0) }
            .map { $0.replacingOccurrences(of: "com.apple.developer.", with: "").replacingOccurrences(of: "com.apple.", with: "") }
            .sorted()
        return names.isEmpty ? "nothing beyond the basics" : names.joined(separator: ", ")
    }

    /// The profile's plist, from inside its signature: the XML between `<?xml` and
    /// `</plist>`, which is how it sits in the file.
    static func profile(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        let xml = data.subdata(in: start.lowerBound..<end.upperBound)
        return (try? PropertyListSerialization.propertyList(from: xml, format: nil)) as? [String: Any]
    }
}
