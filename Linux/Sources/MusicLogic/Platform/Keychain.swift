import Foundation

/// The iPhone's Keychain wrapper, kept in the app's own folder: one small file per item,
/// readable by this user alone, under the same names and as the same JSON as the phone's
/// two Keychain items.
///
/// Not the desktop's keyring. Through the Secret Service that means KWallet or GNOME
/// Keyring, which can ask for a password or a first-run wizard at any moment, can fail to
/// answer at all, and with KWallet not set up keeps what it is given in memory only — and
/// signs the app out at the next reboot. The server is on a LAN behind the same login,
/// and a file only this user can read is what most desktop music players use.
///
/// The server's address and the username are also kept in the settings, which are not
/// secret, so signing in again — on a new install, after Sign Out — starts filled in.
enum Keychain {
    private static let account = "server-credentials"
    private static let requestAccount = "music-request-webhook"
    static let lastServerKey = "signIn.server"
    static let lastUsernameKey = "signIn.username"

    static func save(_ credentials: SubsonicClient.Credentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        UserDefaults.standard.set(credentials.baseURL.absoluteString, forKey: lastServerKey)
        UserDefaults.standard.set(credentials.username, forKey: lastUsernameKey)
        write(data, account: account)
    }

    static func loadCredentials() -> SubsonicClient.Credentials? {
        guard let data = read(account: account) else { return nil }
        return try? JSONDecoder().decode(SubsonicClient.Credentials.self, from: data)
    }

    static func clear() {
        delete(account: account)
    }

    // MARK: - Music request webhook

    static func saveMusicRequestConfiguration(_ configuration: MusicRequestService.Configuration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        write(data, account: requestAccount)
    }

    static func loadMusicRequestConfiguration() -> MusicRequestService.Configuration? {
        guard let data = read(account: requestAccount) else { return nil }
        return try? JSONDecoder().decode(MusicRequestService.Configuration.self, from: data)
    }

    static func clearMusicRequestConfiguration() {
        delete(account: requestAccount)
    }

    // MARK: - Files

    private static func file(_ account: String) -> URL {
        Paths.root.appendingPathComponent(".\(account).json")
    }

    /// Written whole beside the old one, private from the moment it exists, then moved
    /// over it: a crash part-way never leaves half a file, or a readable one.
    private static func write(_ data: Data, account: String) {
        let url = file(account)
        let temporary = url.appendingPathExtension("new")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(temporary.path, url.path) == 0
        else {
            Task { await Diagnostics.shared.record("credentials", "could not save \(account)") }
            return
        }
    }

    private static func read(account: String) -> Data? {
        try? Data(contentsOf: file(account))
    }

    private static func delete(account: String) {
        try? FileManager.default.removeItem(at: file(account))
    }
}
