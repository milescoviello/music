import Foundation
import Testing
@testable import MusicLogic

struct LyricLanguageTests {
    @Test func codesComeDownToTheirBaseLanguage() {
        #expect(LyricLanguage.base("ja-JP") == "ja")
        #expect(LyricLanguage.base("zh-Hans") == "zh")
        #expect(LyricLanguage.base("EN_us") == "en")
        #expect(LyricLanguage.base("ko") == "ko")
    }

    @Test func codesForDontKnowAreNil() {
        #expect(LyricLanguage.base(nil) == nil)
        #expect(LyricLanguage.base("") == nil)
        #expect(LyricLanguage.base("und") == nil)
        #expect(LyricLanguage.base("xxx") == nil)
    }

    @Test func kanaAnywhereMakesTheSongJapanese() {
        // A line of kanji alone reads as Chinese to the recogniser; the kana two lines
        // later settle it.
        let lines = ["罪と罰", "Baby, baby", "×と○と罪と"]
        #expect(LyricLanguage.resolve(detected: "zh-Hans", lines: lines) == "ja")
    }

    @Test func hangulMakesTheSongKorean() {
        #expect(LyricLanguage.resolve(detected: "ja", lines: ["사랑해", "I love you"]) == "ko")
    }

    @Test func otherwiseTheRecogniserDecides() {
        #expect(LyricLanguage.resolve(detected: "zh-Hant", lines: ["你好世界"]) == "zh")
        #expect(LyricLanguage.resolve(detected: "ja", lines: ["東京"]) == "ja")
        #expect(LyricLanguage.resolve(detected: "und", lines: ["la la la"]) == nil)
        // The katakana middle dot is punctuation Chinese uses too.
        #expect(LyricLanguage.resolve(detected: "zh", lines: ["约翰・列侬"]) == "zh")
    }

    @Test func englishIsRecognisedInAnyForm() {
        #expect(LyricLanguage.isEnglish("en"))
        #expect(LyricLanguage.isEnglish("en-GB"))
        #expect(!LyricLanguage.isEnglish("ja"))
        #expect(!LyricLanguage.isEnglish(nil))
    }
}

struct RomanizationTests {
    @Test func latinLinesAreLeftAlone() {
        #expect(!Romanization.needsRomanizing("Hello, world"))
        #expect(!Romanization.needsRomanizing("Café déjà vu"))
        #expect(!Romanization.needsRomanizing("1, 2, 3 ♪ ×"))
        #expect(!Romanization.needsRomanizing(""))
        #expect(Romanization.lines(["Hello", "", "♪"], language: "en") == [nil, nil, nil])
    }

    @Test func anyOtherScriptIsRomanized() {
        #expect(Romanization.needsRomanizing("ハルカリノオカワリ"))
        #expect(Romanization.needsRomanizing("Привет"))
        #expect(Romanization.needsRomanizing("Baby 사랑해"))
    }

    @Test func eachLineGetsItsOwnEntry() {
        let lines = ["Привет, мир!", "Hello", "Καλημέρα"]
        #expect(Romanization.lines(lines, language: nil) == ["Privet, mir!", nil, "Kalemera"])
    }

    @Test func chineseIsPinyinWithoutTones() {
        #expect(Romanization.lines(["你好世界"], language: "zh") == ["ni hao shi jie"])
    }

    @Test func koreanComesOutInPlainLetters() throws {
        let roman = try #require(Romanization.lines(["한국어 노래"], language: "ko")[0])
        #expect(roman.contains("nolae"))
        #expect(roman.unicodeScalars.allSatisfy { $0.isASCII })
    }

    @Test func kanaIsSpelledOut() throws {
        // The tokenizer on Apple's platforms may space the words; the letters are the same.
        let roman = try #require(Romanization.lines(["ハルカリノオカワリ"], language: "ja")[0])
        #expect(roman.replacingOccurrences(of: " ", with: "") == "harukarinookawari")
    }

    @Test func fullWidthPunctuationBecomesLatin() {
        #expect(Romanization.lines(["Привет，мир！"], language: nil) == ["Privet, mir!"])
        #expect(Romanization.latinPunctuation("「君の名は」、好きだ。") == "“君の名は”,好きだ.")
        #expect(Romanization.latinPunctuation("ＬＯＶＥ　ｓｏｎｇ") == "LOVE song")
    }

    @Test func spacingIsTidiedAroundPunctuation() {
        #expect(Romanization.tidySpacing("  kimi , suki .  ") == "kimi, suki.")
        #expect(Romanization.tidySpacing("“ kimi no na wa ” to") == "“kimi no na wa” to")
        #expect(Romanization.tidySpacing("ni hao,shi jie") == "ni hao, shi jie")
        #expect(Romanization.tidySpacing("3.5 ...") == "3.5...")
    }

    @Test func particlesAreWrittenAsTheyAreSaid() {
        #expect(Romanization.japaneseWord("は", transcription: "ha") == "wa")
        #expect(Romanization.japaneseWord("へ", transcription: "he") == "e")
        #expect(Romanization.japaneseWord("を", transcription: "wo") == "o")
        #expect(Romanization.japaneseWord("罪", transcription: "tsumi") == "tsumi")
        // A word the tokenizer could not read still comes out in letters.
        #expect(Romanization.japaneseWord("カワ", transcription: nil) == "kawa")
    }

    #if canImport(Darwin)
    @Test func kanjiIsReadAsJapaneseInAJapaneseSong() throws {
        let roman = try #require(Romanization.lines(["×と○と罪と"], language: "ja")[0])
        #expect(roman.contains("tsumi"))

        let tokyo = try #require(Romanization.lines(["東京へ行きます"], language: "ja")[0])
        #expect(tokyo.lowercased().contains("tokyo"))
        #expect(tokyo.unicodeScalars.allSatisfy { $0.isASCII })
    }

    @Test func kanjiIsReadAsMandarinInAChineseSong() {
        #expect(Romanization.lines(["东京"], language: "zh") == ["dong jing"])
    }
    #endif
}
