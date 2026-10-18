import Foundation

/// Which language a song's lyrics are in, as far as reading along needs to know.
///
/// The server's `lang` tag is not trusted: taggers leave it "eng" or "xxx" whatever the
/// words are. The text decides — the platform's recogniser in the app, and the script
/// here, which is certain where the recogniser can only guess.
enum LyricLanguage {
    /// The base language ("ja", "en", "zh") of a code in whatever form it arrives —
    /// "ja-JP", "zh-Hans", "en_US" — or nil for one that means "don't know".
    static func base(_ code: String?) -> String? {
        guard let code else { return nil }
        let base = code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
        guard let base, !base.isEmpty, !unknown.contains(base) else { return nil }
        return base
    }

    /// The lyrics' language, given what the recogniser made of them.
    ///
    /// Kana can only be Japanese and hangul only Korean, so either one anywhere in the
    /// song overrides the recogniser — which matters for a Japanese line in kanji alone,
    /// read on its own as Chinese.
    static func resolve(detected: String?, lines: [String]) -> String? {
        let scalars = lines.lazy.flatMap(\.unicodeScalars)
        if scalars.contains(where: isKana) { return "ja" }
        if scalars.contains(where: isHangul) { return "ko" }
        return base(detected)
    }

    static func isEnglish(_ code: String?) -> Bool { base(code) == "en" }

    /// Undetermined, no linguistic content, multiple, and the "xxx" taggers write.
    private static let unknown: Set<String> = ["und", "zxx", "mul", "xxx"]

    /// The katakana middle dot is left out: Chinese uses it between the parts of a
    /// foreign name.
    static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30FB: return false
        case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return true
        default: return false
        }
    }

    static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7AF, 0xD7B0...0xD7FF: return true
        default: return false
        }
    }
}

/// Lyrics in Latin letters, for singing along to a script you can't read.
///
/// Diacritics are taken off everything, so every script reads the same plain way:
/// "Tokyo" rather than "Tōkyō", "ni hao" rather than "nǐ hǎo".
enum Romanization {
    /// One entry per line: its romanization, or nil where the line is already in Latin
    /// letters or has none at all, so the view leaves it as it is.
    ///
    /// `language` is the whole song's, from `LyricLanguage.resolve`: Japanese is read
    /// as Japanese only if the song is, since a line of kanji alone could be either.
    static func lines(_ lines: [String], language: String?) -> [String?] {
        let japanese = LyricLanguage.base(language) == "ja"
        return lines.map { needsRomanizing($0) ? romanize($0, japanese: japanese) : nil }
    }

    /// Whether any letter in the text is outside the Latin script.
    static func needsRomanizing(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isAlphabetic && !isLatin($0) }
    }

    static func romanize(_ line: String, japanese: Bool) -> String? {
        let text = latinPunctuation(line)
        var roman: String
        #if canImport(Darwin)
        roman = japanese ? japaneseReading(text) : latin(text)
        #else
        // No Japanese tokenizer outside Apple's platforms, so kanji would read as Mandarin
        // here. Only the test package builds for Linux, and it tests kanji on macOS.
        roman = latin(text)
        #endif
        roman = roman.applyingTransform(.stripDiacritics, reverse: false) ?? roman
        roman = tidySpacing(roman)
        return roman.isEmpty || roman == line ? nil : roman
    }

    /// ICU's own transliteration. For Han it gives Mandarin pinyin, which is right for
    /// Chinese and wrong for Japanese — hence the tokenizer below.
    private static func latin(_ text: String) -> String {
        text.applyingTransform(.toLatin, reverse: false) ?? text
    }

    #if canImport(Darwin)
    /// Japanese read the Japanese way: the system's Japanese tokenizer splits the line
    /// into words and gives each one's reading in romaji, so kanji come out as the words
    /// they are in that sentence. Words are spaced, as romaji is written.
    private static func japaneseReading(_ text: String) -> String {
        let string = text as NSString
        // Typed so the guard holds however the SDK annotates the result.
        let tokenizer: CFStringTokenizer? = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            text as CFString,
            CFRange(location: 0, length: string.length),
            kCFStringTokenizerUnitWordBoundary | kCFStringTokenizerAttributeLatinTranscription,
            Locale(identifier: "ja") as CFLocale
        )
        guard let tokenizer else { return latin(text) }

        var words: [String] = []
        var cursor = 0
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            // Anything the tokenizer stepped over is kept rather than lost.
            if range.location > cursor {
                words.append(latin(string.substring(with: NSRange(location: cursor, length: range.location - cursor))))
            }
            let token = string.substring(with: NSRange(location: range.location, length: range.length))
            let transcription = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer,
                kCFStringTokenizerAttributeLatinTranscription
            ) as? String
            words.append(japaneseWord(token, transcription: transcription))
            cursor = range.location + range.length
        }
        if cursor < string.length {
            words.append(latin(string.substring(from: cursor)))
        }
        return words.joined(separator: " ")
    }
    #endif

    /// One word of Japanese in romaji: the tokenizer's reading, the particles as Hepburn
    /// writes them, and ICU's for a word the tokenizer could not read (right for kana,
    /// which is most of what it misses).
    static func japaneseWord(_ token: String, transcription: String?) -> String {
        if let particle = particles[token] { return particle }
        if let transcription, !transcription.isEmpty { return transcription }
        return latin(token)
    }

    /// The tokenizer reads a particle by its kana — "watashi ha" — where it is spoken
    /// "watashi wa". Standing alone as a word, these three are always the particle.
    private static let particles = ["は": "wa", "へ": "e", "を": "o"]

    /// East Asian punctuation and full-width letters as their Latin equivalents, before
    /// romanizing, so the result reads as one script: corner brackets become quotation
    /// marks, the ideographic comma and full stop become ", " and ". ".
    static func latinPunctuation(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3000, 0x30FB: result.append(" ")
            case 0x3001: result.append(",")
            case 0x3002: result.append(".")
            case 0x300C, 0x300E, 0x3008, 0x300A: result.append("“")
            case 0x300D, 0x300F, 0x3009, 0x300B: result.append("”")
            case 0x3010: result.append("[")
            case 0x3011: result.append("]")
            case 0x301C: result.append("~")
            // Full-width ASCII, "！" to "～", sits a fixed distance above ASCII.
            case 0xFF01...0xFF5E: result.append(Unicode.Scalar(scalar.value - 0xFEE0) ?? scalar)
            default: result.append(scalar)
            }
        }
        return String(result)
    }

    /// One space between words, none inside quotation marks or brackets or before
    /// punctuation, and one after a comma or full stop that runs into the next word.
    static func tidySpacing(_ text: String) -> String {
        let closing: Set<Character> = [",", ".", "!", "?", ";", ":", ")", "]", "”", "»", "…"]
        let opening: Set<Character> = ["(", "[", "“", "«"]
        let separating: Set<Character> = [",", ".", "!", "?", ";", ":"]

        var result = ""
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                pendingSpace = !result.isEmpty
                continue
            }
            if let last = result.last {
                let spaced = pendingSpace || (separating.contains(last) && character.isLetter)
                if spaced, !closing.contains(character), !opening.contains(last) {
                    result.append(" ")
                }
            }
            result.append(character)
            pendingSpace = false
        }
        return result
    }

    /// Latin, including the extended blocks, combining marks, and full-width Latin.
    private static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0xAA, 0xBA, 0xC0...0x24F, 0x250...0x36F,
             0x1D00...0x1DBF, 0x1E00...0x1EFF, 0x2070...0x209F, 0x2100...0x218F,
             0x24B6...0x24E9, 0x2C60...0x2C7F, 0xA720...0xA7FF, 0xAB30...0xAB6F,
             0xFB00...0xFB06, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
            return true
        default:
            return false
        }
    }
}
