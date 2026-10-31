import Foundation

/// The words the library's names are written in, so a search can be put right before it
/// goes to the server.
///
/// `search3` matches each word of a query against the start of a word in a name, exactly.
/// Verified on this server: "cigarets after sex" finds nothing, and "k" finds nothing at
/// all, while "K." finds Cigarettes After Sex's "K.". The server's matching is left alone;
/// the query is put right instead. A word the library spells another way ("k" for "K.",
/// "acdc" for "AC/DC", "cafune" for "CAFUNÉ") takes the library's spelling, a word it does
/// not have at all takes the closest one it does, and two words run together are split.
/// The corrected query is searched as well as the typed one, never instead of it.
struct SearchVocabulary: Codable, Sendable, Equatable {
    /// Normalised words, sorted, so finding the start of one is a binary search.
    private(set) var words: [String] = []
    /// How many names each word is in. Between two equally close corrections, the more
    /// common word is the likelier one.
    private(set) var counts: [Int] = []
    /// Each word as the library most often writes it, which is what gets searched for.
    private(set) var spellings: [String] = []
    private(set) var builtAt: Date = .distantPast

    var isEmpty: Bool { words.isEmpty }
    var count: Int { words.count }

    static func build(names: some Sequence<String>, at date: Date = .now) -> SearchVocabulary {
        var tally: [String: [String: Int]] = [:]
        for name in names {
            for token in name.split(whereSeparator: \.isWhitespace) {
                // Brackets and quotes round a word are the name's, not the word's: "(Live)"
                // is searched as "Live". A full stop stays, since "K." is what finds "K.".
                let spelling = String(token).trimmingCharacters(in: wrapping)
                let key = normalised(spelling)
                guard !key.isEmpty else { continue }
                tally[key, default: [:]][spelling, default: 0] += 1
            }
        }

        var vocabulary = SearchVocabulary()
        vocabulary.builtAt = date
        for key in tally.keys.sorted() {
            guard let spellings = tally[key],
                  // The commonest spelling; a tie goes to the one that sorts first, so the
                  // same library always builds the same vocabulary.
                  let best = spellings.max(by: { a, b in
                      a.value != b.value ? a.value < b.value : a.key > b.key
                  })
            else { continue }
            vocabulary.words.append(key)
            vocabulary.counts.append(spellings.values.reduce(0, +))
            vocabulary.spellings.append(best.key)
        }
        return vocabulary
    }

    private static let wrapping = CharacterSet(charactersIn: "()[]{}\"“”‘’'«»,;:!?")

    /// Case, accents, width and punctuation do not make two words different: "K." is "k",
    /// "AC/DC" is "acdc", "Don’t" is "dont".
    static func normalised(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        return String(kept)
    }

    // MARK: - Correcting

    /// The query as the library would write it, or nil when it already does.
    func correction(for query: String) -> String? {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty, !isEmpty else { return nil }

        var changed = false
        let corrected = tokens.map { token -> String in
            guard let better = correction(forWord: token) else { return token }
            changed = true
            return better
        }
        return changed ? corrected.joined(separator: " ") : nil
    }

    /// One word, or nil to send it as it is.
    ///
    /// The order was found on the real library, 61,037 names: a one-letter slip is put
    /// right before two words run together are split, or "radiohed" became "Radio Hed"
    /// and "kesoku" became "KE Soku". Words are compared whole, never by how they start:
    /// matching starts made "clairo" "Clairvoyants" and "swfit" "Switch".
    func correction(forWord token: String) -> String? {
        let key = Self.normalised(token)
        guard !key.isEmpty else { return nil }

        if let index = index(of: key) {
            let spelling = spellings[index]
            return spelling.lowercased() == token.lowercased() ? nil : spelling
        }
        // The start of a word the library has: still being typed, and `search3` matches
        // the starts of words anyway.
        if isPrefix(key) { return nil }

        let typed = Array(key.unicodeScalars)
        let allowed = Self.allowedEdits(forLength: typed.count)
        if allowed > 0, let index = closest(to: typed, limit: 1) { return spellings[index] }
        if let split = split(key) { return split }
        if allowed > 1, let index = closest(to: typed, limit: allowed) { return spellings[index] }
        return nil
    }

    /// How many edits a word of this length may be from the one it is corrected to.
    /// None for one or two letters; for three, one, and only a letter left out (see
    /// `closest`), since "prk" is a step from too many words otherwise.
    static func allowedEdits(forLength length: Int) -> Int {
        switch length {
        case ..<3: return 0
        case 3...5: return 1
        default: return 2
        }
    }

    private func closest(to typed: [Unicode.Scalar], limit: Int) -> Int? {
        var best: (index: Int, distance: Int, contains: Bool, sameStart: Bool, count: Int)?
        for (index, word) in words.enumerated() {
            let length = word.unicodeScalars.count
            if abs(length - typed.count) > limit { continue }
            let candidate = Array(word.unicodeScalars)
            guard let distance = Self.distance(typed, candidate, limit: limit) else { continue }

            // Between equally close words: one that has every typed letter in order
            // first, because a letter left out is the commonest slip ("elish" is
            // "eilish", not "elise"); then one with the same first letter, since slips
            // are rarely there; then the commoner word.
            let contains = Self.isSubsequence(typed, of: candidate)
            let sameStart = candidate.first == typed.first
            if typed.count <= 3, !(contains && sameStart) { continue }
            if let current = best {
                let mine = (distance, contains ? 0 : 1, sameStart ? 0 : 1, -counts[index])
                let theirs = (current.distance, current.contains ? 0 : 1, current.sameStart ? 0 : 1, -current.count)
                if mine >= theirs { continue }
            }
            best = (index, distance, contains, sameStart, counts[index])
        }
        return best?.index
    }

    private static func isSubsequence(_ short: [Unicode.Scalar], of long: [Unicode.Scalar]) -> Bool {
        var remaining = short[...]
        for scalar in long where remaining.first == scalar {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }

    /// Two words run together: "tameimpala", "pinkfloyd".
    private func split(_ key: String) -> String? {
        let scalars = Array(key.unicodeScalars)
        guard scalars.count >= 5 else { return nil }

        var best: (text: String, weight: Int)?
        for cut in 2...(scalars.count - 2) {
            var left = String.UnicodeScalarView(), right = String.UnicodeScalarView()
            left.append(contentsOf: scalars[..<cut])
            right.append(contentsOf: scalars[cut...])
            guard let l = index(of: String(left)), let r = index(of: String(right)) else { continue }
            let weight = min(counts[l], counts[r])
            if weight > best?.weight ?? 0 { best = ("\(spellings[l]) \(spellings[r])", weight) }
        }
        return best?.text
    }

    /// Edits between `a` and `b`, or nil when there are more than `limit`. An edit is an
    /// insertion, a deletion, a substitution, or two neighbours swapped ("imapla" is one
    /// from "impala").
    static func distance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar], limit: Int) -> Int? {
        let n = a.count, m = b.count
        if abs(n - m) > limit { return nil }
        guard n > 0 else { return m <= limit ? m : nil }

        var beforeLast = [Int](repeating: 0, count: m + 1)
        var last = Array(0...m)
        var row = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            row[0] = i
            var rowMinimum = i
            for j in stride(from: 1, through: m, by: 1) {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(last[j] + 1, row[j - 1] + 1, last[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, beforeLast[j - 2] + 1)
                }
                row[j] = value
                rowMinimum = min(rowMinimum, value)
            }
            // A row never gets cheaper than the one before it.
            if rowMinimum > limit { return nil }
            (beforeLast, last, row) = (last, row, beforeLast)
        }
        return last[m] <= limit ? last[m] : nil
    }

    // MARK: - Looking up

    /// The first word not less than `key`.
    private func lowerBound(_ key: String) -> Int {
        var low = 0, high = words.count
        while low < high {
            let middle = (low + high) / 2
            if words[middle] < key { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private func index(of key: String) -> Int? {
        let index = lowerBound(key)
        return index < words.count && words[index] == key ? index : nil
    }

    private func isPrefix(_ key: String) -> Bool {
        let index = lowerBound(key)
        return index < words.count && words[index].hasPrefix(key)
    }
}
