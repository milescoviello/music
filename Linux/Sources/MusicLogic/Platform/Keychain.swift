import CGtk
import CSecret
import Foundation

/// The iPhone's Keychain wrapper, on the desktop's keyring.
///
/// libsecret talks to whatever implements the Secret Service — GNOME Keyring, or KWallet
/// on Plasma — so the password lives where the desktop keeps every other password. Same
/// two items as on the phone, as JSON, under the same names.
///
/// When there is no keyring to keep things in — a bare window manager, a session with no
/// D-Bus secrets service, or KWallet with no wallet set up, whose "keyring" forgets
/// everything at logout — it falls back to a file only this user can read. Signing in on
/// every launch would be worse than that, and the server is on a LAN behind the same
/// login anyway; the fallback is recorded in Diagnostics so it is never a secret itself.
///
/// The server's address and the username are kept in the settings as well, which are not
/// secret: whatever becomes of the password, signing in again starts filled in.
enum Keychain {
    private static let account = "server-credentials"
    private static let requestAccount = "music-request-webhook"
    static let lastServerKey = "signIn.server"
    static let lastUsernameKey = "signIn.username"

    static func save(_ credentials: SubsonicClient.Credentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        UserDefaults.standard.set(credentials.baseURL.absoluteString, forKey: lastServerKey)
        UserDefaults.standard.set(credentials.username, forKey: lastUsernameKey)
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
    //
    // Every call goes to libsecret on a thread of its own, never the UI's. A keyring can
    // ask for a password or show a first-run wizard, and with some Secret Service builds
    // its answer never arrives at all — KWallet's "Completed" signal carries a type
    // libsecret does not expect, the call waits forever, and on the UI thread that froze
    // the window for good. So reads wait a few seconds and then use the private file, and
    // writes carry on in the background, falling back to the file if the keyring fails.

    private static func write(_ data: Data, account: String, label: String) {
        let secret = String(decoding: data, as: UTF8.self)
        DispatchQueue.global(qos: .userInitiated).async {
            let stored = withTimeout(10) {
                // Stored without a default collection, it would last only until logout.
                guard csecret_has_default_collection() != 0 else { return false }
                return withAttributes(account) { attributes in
                    var error: UnsafeMutablePointer<GError>?
                    let ok = secret_password_storev_sync(
                        csecret_music_schema(), attributes, "default", label, secret, nil, &error
                    )
                    if let error { g_error_free(error) }
                    return ok != 0
                }
            } ?? false
            if stored {
                // A file left by an earlier session without a keyring would otherwise
                // outlive the item that replaced it.
                try? FileManager.default.removeItem(at: fallbackFile(account))
            } else {
                writeFallback(data, account: account)
            }
        }
    }

    private static func read(account: String) -> Data? {
        let found: (data: Data, lasting: Bool)? = withTimeout(4) {
            withAttributes(account) { attributes -> (data: Data, lasting: Bool)? in
                var error: UnsafeMutablePointer<GError>?
                let password = secret_password_lookupv_sync(csecret_music_schema(), attributes, nil, &error)
                if let error { g_error_free(error) }
                guard let password else { return nil }
                defer { secret_password_free(password) }
                return (Data(String(cString: password).utf8), csecret_has_default_collection() != 0)
            }
        } ?? nil
        if let found {
            // Found only in a keyring with nowhere lasting to keep it: kept in the file too,
            // so the next login still has it.
            if !found.lasting { writeFallback(found.data, account: account) }
            return found.data
        }
        return try? Data(contentsOf: fallbackFile(account))
    }

    private static func delete(account: String) {
        try? FileManager.default.removeItem(at: fallbackFile(account))
        DispatchQueue.global(qos: .utility).async {
            _ = withTimeout(10) {
                withAttributes(account) { attributes in
                    var error: UnsafeMutablePointer<GError>?
                    secret_password_clearv_sync(csecret_music_schema(), attributes, nil, &error)
                    if let error { g_error_free(error) }
                }
            }
        }
    }

    /// Runs a keyring call on its own thread and waits at most `seconds` for it. Nil if it
    /// did not answer in time; the thread is left to finish, or not, on its own.
    private static func withTimeout<T: Sendable>(_ seconds: Double, _ body: @escaping @Sendable () -> T) -> T? {
        let result = KeyringResult<T>()
        let done = DispatchSemaphore(value: 0)
        Thread {
            result.value = body()
            done.signal()
        }.start()
        guard done.wait(timeout: .now() + seconds) == .success else {
            Task { await Diagnostics.shared.record("keyring", "the Secret Service did not answer in \(Int(seconds)) s") }
            return nil
        }
        return result.value
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
        _ = FileManager.default.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        )
        Task { await Diagnostics.shared.record("keyring", "no Secret Service; \(account) kept in a private file") }
    }
}

/// What a keyring call on its own thread hands back.
private final class KeyringResult<Value>: @unchecked Sendable {
    var value: Value?
}
