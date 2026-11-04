import Foundation

/// Navidrome's stand-in for a missing cover: a blue "navidrome" record, the same 1024 px
/// WebP whatever size is asked for, sent with a 200 like a real cover.
///
/// Kept as if it were the album's own, it stayed after the album got a cover: Ginkgo's
/// songs showed the record on the phone long after its `cover.jpg` was in place (their
/// cover ids never change, so nothing fetched again). Recognised, it is not kept, and the
/// app draws its own placeholder, the initials, until there is a cover.
enum CoverPlaceholder {
    /// The size of Navidrome 0.64's placeholder, which is the same bytes for every album.
    static let byteCount = 69_228

    static func isServerPlaceholder(_ data: Data) -> Bool {
        guard data.count == byteCount else { return false }
        let riff: [UInt8] = [0x52, 0x49, 0x46, 0x46]
        let webp: [UInt8] = [0x57, 0x45, 0x42, 0x50]
        return data.starts(with: riff) && data.dropFirst(8).starts(with: webp)
    }

    /// Deletes kept copies of it from a folder, once, when this check arrives.
    @discardableResult
    static func purge(in directory: URL) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        var removed = 0
        for file in files {
            guard (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) == byteCount,
                  let data = try? Data(contentsOf: file), isServerPlaceholder(data)
            else { continue }
            try? FileManager.default.removeItem(at: file)
            removed += 1
        }
        return removed
    }
}
