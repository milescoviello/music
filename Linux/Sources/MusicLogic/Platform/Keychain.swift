import CGtk
import CSecret
import Foundation

/// The iPhone's Keychain wrapper, on the desktop's keyring.
///
/// libsecret talks to whatever implements the Secret Service — GNOME Keyring, or KWallet
/// on Plasma — so the password lives where the desktop keeps every other password. Same
/// two items as on the phone, as JSON, under the same names.
///
/// When there is no keyring at all — a bare window manager, a session with no D-Bus
/// secrets service — it falls back to a file only this user can read. Signing in on
/// every launch would be worse than that, and the server is on a LAN behind the same
/// login anyway; the fallback is recorded in Diagnostics so it is never a secret itself.
enum Keychain {
    private static let account = "server-credentials"
    private static let requestAccount = "music-request-webhook"

    static func save(_ credentials: SubsonicClient.Credentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        write(data, account: account, label: "Music: Navidrome sign-in")
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
        write(data, account: requestAccount, label: "Music: request webhook")
    }

    static func loadMusicRequestConfiguration() -> MusicRequestService.Configuration? {
        guard let data = read(account: requestAccount) else { return nil }
        return try? JSONDecoder().decode(MusicRequestService.Configuration.self, from: data)
    }

    static func clearMusicRequestConfiguration() {
        delete(account: requestAccount)
    }

    // MARK: - Plumbing

    private static func write(_ data: Data, account: String, label: String) {
        let secret = String(decoding: data, as: UTF8.self)
        let stored = withAttributes(account) { attributes in
            var error: UnsafeMutablePointer<GError>?
            let ok = secret_password_storev_sync(
                csecret_music_schema(), attributes, "default", label, secret, nil, &error
            )
            if let error { g_error_free(error) }
            return ok != 0
        }
        if stored {
            // A file left by an earlier session without a keyring would otherwise outlive
            // the item that replaced it.
            try? FileManager.default.removeItem(at: fallbackFile(account))
            return
        }
        writeFallback(data, account: account)
    }

    private static func read(account: String) -> Data? {
        let found: Data? = withAttributes(account) { attributes in
            var error: UnsafeMutablePointer<GError>?
            let password = secret_password_lookupv_sync(csecret_music_schema(), attributes, nil, &error)
            if let error { g_error_free(error) }
            guard let password else { return nil }
            defer { secret_password_free(password) }
            return Data(String(cString: password).utf8)
        }
        return found ?? (try? Data(contentsOf: fallbackFile(account)))
    }

    private static func delete(account: String) {
        _ = withAttributes(account) { attributes in
            var error: UnsafeMutablePointer<GError>?
            secret_password_clearv_sync(csecret_music_schema(), attributes, nil, &error)
            if let error { g_error_free(error) }
        }
        try? FileManager.default.removeItem(at: fallbackFile(account))
    }

    private static func withAttributes<T>(_ account: String, _ body: (OpaquePointer?) -> T) -> T {
        let table = g_hash_table_new(g_str_hash, g_str_equal)
        defer { g_hash_table_unref(table) }
        return "account".withCString { key in
            account.withCString { value in
                g_hash_table_insert(table, UnsafeMutableRawPointer(mutating: key), UnsafeMutableRawPointer(mutating: value))
                return body(table)
            }
        }
    }

    // MARK: - Without a keyring

    private static func fallbackFile(_ account: String) -> URL {
        Paths.root.appendingPathComponent(".\(account).json")
    }

    private static func writeFallback(_ data: Data, account: String) {
        let url = fallbackFile(account)
        FileManager.default.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        )
        Task { await Diagnostics.shared.record("keyring", "no Secret Service; \(account) kept in a private file") }
    }
}
