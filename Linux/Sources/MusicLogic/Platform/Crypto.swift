import CGtk
import Foundation

// The two digests the Core asks CryptoKit for, under CryptoKit's own names so the files
// that use them compile unchanged: Subsonic's salted MD5 token, and the Hermes gateway's
// HMAC-SHA256 signature. GLib has both, and is linked anyway.

enum Insecure {
    enum MD5 {
        static func hash(data: Data) -> [UInt8] {
            GLibDigest.checksum(G_CHECKSUM_MD5, data)
        }
    }
}

enum SHA256 {}

struct SymmetricKey {
    let data: Data

    init(data: Data) {
        self.data = data
    }
}

enum HMAC<Function> {
    /// SHA-256 is the only function anything here signs with.
    static func authenticationCode(for message: Data, using key: SymmetricKey) -> [UInt8] {
        precondition(Function.self == SHA256.self, "only HMAC-SHA256 is provided on Linux")
        return key.data.withUnsafeBytes { keyBytes in
            let hmac = g_hmac_new(
                G_CHECKSUM_SHA256,
                keyBytes.baseAddress?.assumingMemoryBound(to: guchar.self),
                gsize(keyBytes.count)
            )
            defer { g_hmac_unref(hmac) }
            message.withUnsafeBytes { bytes in
                g_hmac_update(hmac, bytes.baseAddress?.assumingMemoryBound(to: guchar.self), gssize(bytes.count))
            }
            var digest = [UInt8](repeating: 0, count: 32)
            var length = gsize(digest.count)
            g_hmac_get_digest(hmac, &digest, &length)
            return Array(digest.prefix(Int(length)))
        }
    }
}

private enum GLibDigest {
    static func checksum(_ type: GChecksumType, _ data: Data) -> [UInt8] {
        let checksum = g_checksum_new(type)
        defer { g_checksum_free(checksum) }
        data.withUnsafeBytes { bytes in
            g_checksum_update(checksum, bytes.baseAddress?.assumingMemoryBound(to: guchar.self), gssize(bytes.count))
        }
        var digest = [UInt8](repeating: 0, count: Int(g_checksum_type_get_length(type)))
        var length = gsize(digest.count)
        g_checksum_get_digest(checksum, &digest, &length)
        return Array(digest.prefix(Int(length)))
    }
}
