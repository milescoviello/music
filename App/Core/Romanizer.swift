import Foundation
#if canImport(Darwin)
import CoreFoundation
#endif

/// Lyrics in another script spelled out in Latin letters, so they can be sung along to.
///
/// Japanese is read word by word with the system's Japanese tokenizer, because the
/// general transform reads every kanji as Mandarin: 罪 comes out "zuì", not "tsumi".
/// Korean and Cyrillic are spelled by hand, the way readers expect them -- "saranghae",
/// "Ya tebya lyublyu" -- where the general transform writes "salanghae" and
/// "Â tebâ lûblû". Everything else -- Chinese, Greek, Arabic, Thai -- goes through the
/// general transform. Diacritics are stripped throughout ("Tokyo", not "Tōkyō"): this is
/// read at a glance mid-song, and the marks were noise more often than help.
enum Romanizer {
    enum Style: Sendable, Equatable {
        case japanese
        case general
    }

    static func style(forLanguage language: String?) -> Style {
        LyricsLanguage.base(of: language) == "ja" ? .japanese : .general
    }

    /// Each line's romanization, or nil where there is nothing to add: a line already in
    /// Latin letters would only be repeated beneath itself.
    static func romanize(_ lines: [String], language: String?) -> [String?] {
        let style = style(forLanguage: language)
        return lines.map { romanize($0, style: style, language: language) }
    }

    /// `language` only picks the Cyrillic spelling: Ukrainian's г is "h", Bulgarian's ъ "a".
    static func romanize(_ line: String, style: Style, language: String? = nil) -> String? {
        guard needsRomanization(line) else { return nil }
        let raw: String?
        switch style {
        case .japanese:
            #if canImport(Darwin)
            raw = joinJapanese(japaneseTokens(line))
            #else
            // No Japanese tokenizer outside Apple's platforms; only the tests build here.
            raw = line.applyingTransform(.toLatin, reverse: false)
            #endif
        case .general:
            let spelled = cyrillic(hangul(line), language: LyricsLanguage.base(of: language))
            // The general transform marks hard and soft signs outside the table with
            // primes, which say nothing to someone reading along.
            raw = spelled.applyingTransform(.toLatin, reverse: false)?.filter { $0 != "ʹ" && $0 != "ʺ" }
        }
        guard let raw else { return nil }
        let tidied = tidy(raw)
        return tidied.isEmpty || tidied == line ? nil : tidied
    }

    /// Whether any letter is outside the Latin script. Symbols, digits and punctuation
    /// count for nothing either way, so "×と○" needs it and "♪ 1, 2" does not.
    static func needsRomanization(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isAlphabetic && !isLatin($0) }
    }

    static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0000...0x02FF,   // ASCII, Latin-1, Extended-A/B, IPA, spacing modifiers
             0x0300...0x036F,   // combining diacritics
             0x1D00...0x1DBF,   // phonetic extensions
             0x1E00...0x1EFF,   // Latin Extended Additional (Vietnamese)
             0x2C60...0x2C7F, 0xA720...0xA7FF, 0xAB30...0xAB6F,
             0xFF21...0xFF3A, 0xFF41...0xFF5A:   // fullwidth A-Z, a-z
            return true
        default:
            return false
        }
    }

    // MARK: - Japanese

    /// One stretch of a Japanese line: a word, a particle, punctuation or the gap between.
    struct Token: Equatable, Sendable {
        var text: String
        /// The tokenizer's Latin transcription, when it had one.
        var reading: String?
    }

    /// Words romanized and separated by spaces; anything already Latin -- an English
    /// phrase, punctuation, the gaps around them -- kept exactly as written.
    static func joinJapanese(_ tokens: [Token]) -> String {
        var pieces: [String] = []
        var latinRun = ""

        for token in tokens {
            guard needsRomanization(token.text) else {
                latinRun += token.text
                continue
            }
            if !latinRun.isEmpty {
                pieces.append(latinRun)
                latinRun = ""
            }
            pieces.append(reading(of: token))
        }
        if !latinRun.isEmpty { pieces.append(latinRun) }

        return pieces.joined(separator: " ")
    }

    /// The particles は, へ and を are written as "ha", "he" and "wo" but sung "wa", "e" and
    /// "o", and the transcription spells them as written. The tokenizer gives them a
    /// token of their own, which is the only time they can be told from the same kana
    /// inside a word.
    private static func reading(of token: Token) -> String {
        switch token.text {
        case "は": return "wa"
        case "へ": return "e"
        case "を": return "o"
        default:
            return token.reading
                ?? token.text.applyingTransform(.toLatin, reverse: false)
                ?? token.text
        }
    }

    #if canImport(Darwin)
    /// The line cut into words by the system's Japanese tokenizer, each with its reading.
    /// The gaps it skips are kept as tokens of their own, so joining them back loses
    /// nothing.
    private static func japaneseTokens(_ line: String) -> [Token] {
        let string = line as NSString
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            line as CFString,
            CFRange(location: 0, length: string.length),
            kCFStringTokenizerUnitWordBoundary,
            Locale(identifier: "ja") as CFLocale
        )

        var tokens: [Token] = []
        var end = 0
        while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if range.location > end {
                tokens.append(Token(text: string.substring(with: NSRange(location: end, length: range.location - end))))
            }
            let reading = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer,
                kCFStringTokenizerAttributeLatinTranscription
            ) as? String
            tokens.append(Token(
                text: string.substring(with: NSRange(location: range.location, length: range.length)),
                reading: reading
            ))
            end = range.location + range.length
        }
        if end < string.length {
            tokens.append(Token(text: string.substring(from: end)))
        }
        return tokens
    }
    #endif

    // MARK: - Korean

    /// Revised Romanization, a run of syllables at a time: the sound changes it writes
    /// down happen inside a word, where one syllable's final meets the next one's initial.
    /// 한국어 is "hangugeo", 합니다 "hamnida", 그렇게 "geureoke".
    static func hangul(_ text: String) -> String {
        var result = ""
        var run: [Syllable] = []
        for scalar in text.unicodeScalars {
            if let syllable = Syllable(scalar) {
                run.append(syllable)
                continue
            }
            result += revised(run)
            run.removeAll()
            result.unicodeScalars.append(scalar)
        }
        return result + revised(run)
    }

    private struct Syllable {
        let initial: Int
        let vowel: Int
        let final: Int

        /// Unicode composes every syllable as 0xAC00 + (initial × 21 + vowel) × 28 + final.
        init?(_ scalar: Unicode.Scalar) {
            guard (0xAC00...0xD7A3).contains(scalar.value) else { return nil }
            let index = Int(scalar.value - 0xAC00)
            initial = index / 588
            vowel = index % 588 / 28
            final = index % 28
        }
    }

    private static func revised(_ syllables: [Syllable]) -> String {
        var result = ""
        var carried: String?
        for (index, syllable) in syllables.enumerated() {
            result += carried ?? initials[syllable.initial]
            result += vowels[syllable.vowel]
            carried = nil
            guard syllable.final != 0 else { continue }
            guard index + 1 < syllables.count else {
                result += finals[syllable.final]
                continue
            }
            let (final, next) = joint(syllable.final, before: syllables[index + 1].initial)
            result += final
            carried = next
        }
        return result
    }

    /// How a final consonant is said before the next syllable's initial: the spelling of
    /// the final, and the initial in its place when the meeting changes it.
    private static func joint(_ final: Int, before initial: Int) -> (String, String?) {
        switch (final, initial) {
        case (_, 11):
            // A silent ㅇ: the final carries across and is said as the next initial.
            let (stays, moves) = liaison[final]
            return (stays, moves.isEmpty ? nil : moves)
        case (4, 5), (8, 5), (8, 2):
            // ㄴ or ㄹ against ㄹ, and ㄹ against ㄴ, are all said as a long l.
            return ("l", "l")
        case (27, 0), (27, 3), (27, 12), (6, 0), (6, 3), (6, 12), (15, 0), (15, 3), (15, 12):
            // ㅎ breathes into ㄱ, ㄷ and ㅈ.
            return (final == 6 ? "n" : final == 15 ? "l" : "", aspirated[initial])
        case (_, 2), (_, 6):
            // Before ㄴ or ㅁ a stop turns nasal.
            switch finals[final] {
            case "k": return ("ng", nil)
            case "t": return ("n", nil)
            case "p": return ("m", nil)
            case let spelling: return (spelling, nil)
            }
        default:
            return (finals[final], nil)
        }
    }

    private static let initials = [
        "g", "kk", "n", "d", "tt", "r", "m", "b", "pp", "s", "ss", "", "j", "jj", "ch", "k", "t", "p", "h",
    ]
    private static let vowels = [
        "a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o", "wa", "wae", "oe", "yo", "u", "wo", "we",
        "wi", "yu", "eu", "ui", "i",
    ]
    /// A final at the end of a word or before another consonant.
    private static let finals = [
        "", "k", "k", "k", "n", "n", "n", "t", "l", "k", "m", "l", "l", "l", "p", "l", "m", "p", "p",
        "t", "t", "ng", "t", "t", "k", "t", "p", "t",
    ]
    /// A final before a vowel: the part that stays, and the part said with the vowel.
    private static let liaison: [(String, String)] = [
        ("", ""), ("", "g"), ("", "kk"), ("k", "s"), ("", "n"), ("n", "j"), ("", "n"), ("", "d"),
        ("", "r"), ("l", "g"), ("l", "m"), ("l", "b"), ("l", "s"), ("l", "t"), ("l", "p"), ("", "r"),
        ("", "m"), ("", "b"), ("p", "s"), ("", "s"), ("", "ss"), ("ng", ""), ("", "j"), ("", "ch"),
        ("", "k"), ("", "t"), ("", "p"), ("", ""),
    ]
    private static let aspirated = [0: "k", 3: "t", 12: "ch"]

    // MARK: - Cyrillic

    /// The common English spelling of Russian, with Ukrainian's and Belarusian's own
    /// letters, and the few that Ukrainian and Bulgarian say differently. Serbian's own
    /// letters and the rest are left to the general transform.
    static func cyrillic(_ text: String, language: String?) -> String {
        let overrides = cyrillicOverrides[language ?? ""] ?? [:]
        var result = ""
        for character in text {
            let lower = character.lowercased()
            guard let spelling = overrides[lower] ?? cyrillicLetters[lower] else {
                result.append(character)
                continue
            }
            result += character.isUppercase ? spelling.prefix(1).uppercased() + spelling.dropFirst() : spelling
        }
        return result
    }

    private static let cyrillicLetters: [String: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo", "ж": "zh",
        "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o",
        "п": "p", "р": "r", "с": "s", "т": "t", "у": "u", "ф": "f", "х": "kh", "ц": "ts",
        "ч": "ch", "ш": "sh", "щ": "shch", "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu",
        "я": "ya", "і": "i", "ї": "yi", "є": "ye", "ґ": "g", "ў": "w",
    ]

    private static let cyrillicOverrides: [String: [String: String]] = [
        "uk": ["г": "h", "и": "y"],
        "bg": ["ъ": "a", "щ": "sht", "х": "h"],
    ]

    // MARK: - Tidying

    /// CJK punctuation in its Latin form, diacritics off, and spacing as English would
    /// have it: none before a comma or a closing bracket, one after a comma before a
    /// word.
    static func tidy(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "、", "､": scalars.append(",")
            case "。", "｡": scalars.append(".")
            case "「", "『", "《", "〈": scalars.append("“")
            case "」", "』", "》", "〉": scalars.append("”")
            case "【", "〔": scalars.append("[")
            case "】", "〕": scalars.append("]")
            case "〜", "～": scalars.append("~")
            case "・", "\u{3000}": scalars.append(" ")
            default:
                // Fullwidth ASCII -- ！？（），ＡＢＣ１２３ -- shifted to its ordinary form.
                if (0xFF01...0xFF5E).contains(scalar.value),
                   let narrow = Unicode.Scalar(scalar.value - 0xFEE0) {
                    scalars.append(narrow)
                } else {
                    scalars.append(scalar)
                }
            }
        }
        let plain = String(scalars).applyingTransform(.stripDiacritics, reverse: false) ?? String(scalars)
        return respaced(plain)
    }

    private static let closing: Set<Character> = [",", ".", "!", "?", ";", ":", ")", "]", "”", "’", "…"]
    private static let opening: Set<Character> = ["(", "[", "“", "‘"]
    private static let pausing: Set<Character> = [",", ".", "!", "?", ";", ":"]

    private static func respaced(_ text: String) -> String {
        var output = ""
        var pendingSpace = false
        var previous: Character?

        for character in text {
            if character.isWhitespace {
                pendingSpace = previous != nil
                continue
            }
            let afterPause = previous.map { pausing.contains($0) } ?? false
            let wantsSpace = (pendingSpace || (afterPause && (character.isLetter || opening.contains(character))))
            if wantsSpace, !closing.contains(character), let previous, !opening.contains(previous) {
                output.append(" ")
            }
            output.append(character)
            previous = character
            pendingSpace = false
        }
        return output
    }
}
