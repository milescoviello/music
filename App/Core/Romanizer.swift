import Foundation
#if canImport(Darwin)
import CoreFoundation
#endif

/// Lyrics in another script spelled out in Latin letters, so they can be sung along to.
///
/// Japanese is read word by word with the system's Japanese tokenizer, because the
/// general transform reads every kanji as Mandarin: 罪 comes out "zuì", not "tsumi".
/// Everything else -- hangul, Chinese, Cyrillic, Greek, Arabic, Thai -- goes through the
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
        return lines.map { romanize($0, style: style) }
    }

    static func romanize(_ line: String, style: Style) -> String? {
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
            raw = line.applyingTransform(.toLatin, reverse: false)
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
