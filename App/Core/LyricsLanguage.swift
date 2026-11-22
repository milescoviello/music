import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Which language a song's lyrics are in, and which of their lines are worth translating.
enum LyricsLanguage {
    /// A language code from the server's `lang` tag, two letters where there is one.
    /// Tags arrive as ISO 639-2 ("jpn", "eng"), sometimes with a region, and "xxx" or
    /// "und" when nobody knows -- which is nil here, not a language.
    static func code(fromTag tag: String?) -> String? {
        guard let base = base(of: tag), !unknown.contains(base) else { return nil }
        if base.count == 2 { return base }
        return bibliographic[base] ?? Locale.LanguageCode(base).identifier(.alpha2)
    }

    /// The language with any region or script dropped: "zh-Hans" is "zh", "en_GB" "en".
    static func base(of code: String?) -> String? {
        guard let code = code?.trimmingCharacters(in: .whitespaces).lowercased(), !code.isEmpty else {
            return nil
        }
        return String(code.prefix { $0 != "-" && $0 != "_" })
    }

    static func isEnglish(_ code: String?) -> Bool {
        base(of: code) == "en"
    }

    /// Lyrics the desktop romanizes from the sonic service's readings (`SonicClient.readings`):
    /// a script written without spaces whose characters have several readings, which the
    /// letters alone cannot spell out. The phone's own tokenizer reads it there.
    static func readsOnServer(_ code: String?) -> Bool {
        base(of: code) == "ja"
    }

    /// The lyrics' language. In a song written mostly in kana or hangul, the script
    /// settles it outright -- no other language writes in them, and a recognizer can
    /// mistake kanji-heavy Japanese for Chinese. Otherwise the recognizer's guess from the
    /// whole text, then the server's tag, which is often just a tagger's default.
    static func resolve(lines: [String], tag: String?, detected: String?) -> String? {
        let scripts = Scripts(lines)
        if scripts.mostlyOther {
            // A share of the Chinese characters, not just any kana: a Chinese lyric can
            // borrow a stray の for style, while Japanese is full of particles and verb
            // endings that kanji cannot write.
            if scripts.kana > 0, scripts.kana * 5 >= scripts.kana + scripts.han { return "ja" }
            if scripts.hangul * 2 >= scripts.other { return "ko" }
        }
        return detected ?? code(fromTag: tag)
    }

    /// The lyrics' language as both lyrics screens and the downloads' keeping read it: the
    /// system's recognizer over the whole song where there is one (a single line is too
    /// short to tell close languages apart), the letters alone on the desktop, then
    /// `resolve`.
    static func detect(_ lines: [String], tag: String?) -> String? {
        #if canImport(NaturalLanguage)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(lines.joined(separator: "\n"))
        let detected = recognizer.dominantLanguage.flatMap { $0 == .undetermined ? nil : $0.rawValue }
        #else
        let detected = guess(lines)
        #endif
        return resolve(lines: lines, tag: tag, detected: detected)
    }

    /// A guess from the letters alone, for where there is no language recognizer (the
    /// desktop): which Cyrillic language, the one thing the romanization spells
    /// differently. Ukrainian alone writes і, ї, є and ґ; Russian alone ы and э; Bulgarian
    /// writes ъ as a vowel, often, where Russian has it rarely. Nil when the letters do not
    /// settle it, and for anything not in Cyrillic.
    static func guess(_ lines: [String]) -> String? {
        var cyrillic = 0, ukrainian = 0, russian = 0, hard = 0, belarusian = 0
        for line in lines {
            for scalar in line.lowercased().unicodeScalars where (0x0400...0x04FF).contains(scalar.value) {
                cyrillic += 1
                switch scalar {
                case "і", "ї", "є", "ґ": ukrainian += 1
                case "ы", "э", "ё": russian += 1
                case "ъ": hard += 1
                case "ў": belarusian += 1
                default: break
                }
            }
        }
        guard cyrillic >= 20 else { return looksEnglish(lines) ? "en" : nil }
        if belarusian > 0 { return "be" }
        if ukrainian > 0, ukrainian >= russian { return "uk" }
        if russian > 0 { return "ru" }
        if hard * 100 >= cyrillic { return "bg" }
        return nil
    }

    /// English, told by its commonest small words: lyrics in English are full of them, and
    /// lyrics in another language written in the same letters have next to none. Only words
    /// no other language writes the same way. For the desktop, which has no recognizer: it
    /// took every untagged song in Latin letters for one in an unknown language, offered to
    /// translate it, and asked the server for a translation of every English download.
    static func looksEnglish(_ lines: [String]) -> Bool {
        let words = lines.joined(separator: " ").lowercased()
            .split { !$0.isLetter && $0 != "'" && $0 != "’" }
            .map { $0.replacingOccurrences(of: "’", with: "'") }
        guard words.count >= 12 else { return false }
        let common = words.filter(englishWords.contains).count
        return common * 8 >= words.count
    }

    private static let englishWords: Set<String> = [
        "the", "and", "you", "your", "you're", "to", "of", "is", "that", "it", "it's", "i'm", "don't",
        "my", "with", "what", "this", "be", "for", "we", "when", "are", "was", "have", "can", "just",
        "know", "like", "all", "but", "they", "she", "he", "her", "his", "there", "if", "not", "get",
        "got", "want", "never", "feel", "yeah", "baby", "love", "can't", "i'll", "i've", "won't",
    ]

    /// The lines to send for translation. Lines with no letters ("♪", blank) never are.
    /// When the song is mostly in another script, only the lines in that script are --
    /// the English chorus of a J-pop song is already English, and run through a
    /// Japanese-to-English model it comes back mangled rather than unchanged.
    static func linesToTranslate(_ lines: [String]) -> [Int] {
        let mostlyOther = Scripts(lines).mostlyOther
        return lines.indices.filter { index in
            let line = lines[index]
            guard line.unicodeScalars.contains(where: \.properties.isAlphabetic) else { return false }
            return !mostlyOther || Romanizer.needsRomanization(line)
        }
    }

    /// How much of the text is in a script other than Latin, and which.
    private struct Scripts {
        var latin = 0
        var other = 0
        var kana = 0
        var han = 0
        var hangul = 0

        init(_ lines: [String]) {
            for line in lines {
                for scalar in line.unicodeScalars where scalar.properties.isAlphabetic {
                    if Romanizer.isLatin(scalar) {
                        latin += 1
                    } else {
                        other += 1
                        if LyricsLanguage.isKana(scalar) { kana += 1 }
                        if LyricsLanguage.isHan(scalar) { han += 1 }
                        if LyricsLanguage.isHangul(scalar) { hangul += 1 }
                    }
                }
            }
        }

        /// A fifth, not a half: one kanji says what three or four Latin letters do.
        var mostlyOther: Bool {
            other > 0 && other * 5 >= latin + other
        }
    }

    private static let unknown: Set<String> = ["xxx", "und", "zxx", "mul", "mis"]

    /// ISO 639-2's older "B" codes, which Foundation does not map to two letters.
    private static let bibliographic: [String: String] = [
        "chi": "zh", "fre": "fr", "ger": "de", "dut": "nl", "gre": "el", "per": "fa",
        "cze": "cs", "rum": "ro", "slo": "sk", "arm": "hy", "geo": "ka", "alb": "sq",
        "baq": "eu", "bur": "my", "mac": "mk", "may": "ms", "tib": "bo", "wel": "cy",
        "ice": "is",
    ]

    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3041...0x309F, 0x30A1...0x30FA, 0x30FD...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D:
            // Not ・ or ー (0x30FB-0x30FC) on their own: both turn up as decoration in
            // text that is not Japanese at all.
            return true
        default:
            return false
        }
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3005...0x3007, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF:
            return true
        default:
            return false
        }
    }

    private static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3131...0x318E:
            return true
        default:
            return false
        }
    }
}
