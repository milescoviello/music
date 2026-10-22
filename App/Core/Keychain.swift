import Foundation
import Security

/// Minimal Keychain wrapper for the credentials this app stores.
///
/// The app is re-signed roughly weekly (free Apple developer certificate), and a
/// reinstall keeps the same bundle identifier, so the Keychain item survives --
/// unlike anything kept only in the app container.
enum Keychain {
    private static let service = "com.milescoviello.music"
    private static let account = "server-credentials"
    private static let requestAccount = "music-request-webhook"
    private static let remoteAccount = "remote-players"

    static func save(_ credentials: SubsonicClient.Credentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }

        // SecItemUpdate cannot create, and SecItemAdd cannot replace, so delete
        // first and add: the simplest correct write for a single item.
        clear()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    static func loadCredentials() -> SubsonicClient.Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else {
            return nil
        }

        return try? JSONDecoder().decode(SubsonicClient.Credentials.self, from: data)
    }

    static func clear() {
        delete(account: account)
    }

    // MARK: - Music request webhook
    //
    // A second item rather than a field on the credentials: it is a different service
    // with a different lifetime, and signing out of Navidrome should not throw away a
    // working request route.

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

    // MARK: - Remote players
    //
    // The computers this phone has paired with, each with the token it was given. As
    // they are, encoded by `RemotePlayers`, which owns their shape.

    static func saveRemotePlayers(_ data: Data) {
        write(data, account: remoteAccount)
    }

    static func loadRemotePlayers() -> Data? {
        read(account: remoteAccount)
    }

    // MARK: - Plumbing

    private static func write(_ data: Data, account: String) {
        // SecItemUpdate cannot create and SecItemAdd cannot replace, so delete first.
        delete(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func read(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
