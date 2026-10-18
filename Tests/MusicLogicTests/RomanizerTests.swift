import Foundation
import Testing
@testable import MusicLogic

struct RomanizerTests {
    @Test func onlyLettersOutsideLatinNeedIt() {
        #expect(Romanizer.needsRomanization("ハルカリノオカワリ"))
        #expect(Romanizer.needsRomanization("×と○と罪と"))
        #expect(Romanizer.needsRomanization("Привет"))
        #expect(Romanizer.needsRomanization("I love you 사랑해"))
        #expect(!Romanizer.needsRomanization("Déjà vu, ça va"))
        #expect(!Romanizer.needsRomanization("Tiếng Việt"))
        #expect(!Romanizer.needsRomanization("♪ × ○ 1, 2, 3"))
        #expect(!Romanizer.needsRomanization(""))
    }

    @Test func aLineAlreadyInLatinHasNothingToAdd() {
        #expect(Romanizer.romanize("Hello, world", style: .general) == nil)
        #expect(Romanizer.romanize("♪", style: .japanese) == nil)
        #expect(Romanizer.romanize(["Hello", "Привет"], language: "ru") == [nil, "Privet"])
    }

    @Test func otherScriptsGoThroughTheGeneralTransform() {
        #expect(Romanizer.romanize("Привет, мир!", style: .general) == "Privet, mir!")
        #expect(Romanizer.romanize("你好，世界！", style: .general) == "ni hao, shi jie!")
        #expect(Romanizer.romanize("Γεια σου", style: .general) == "Geia sou")
    }

    @Test func koreanIsRevisedRomanization() {
        #expect(Romanizer.romanize("사랑해요", style: .general) == "saranghaeyo")
        #expect(Romanizer.romanize("한국어", style: .general) == "hangugeo")
        // A stop before ㄴ turns nasal; ㅎ breathes into the ㄱ after it; ㄴ meeting ㄹ is a long l.
        #expect(Romanizer.romanize("합니다", style: .general) == "hamnida")
        #expect(Romanizer.romanize("그렇게", style: .general) == "geureoke")
        #expect(Romanizer.romanize("신라", style: .general) == "silla")
        // Sound changes stay inside a word.
        #expect(Romanizer.romanize("밥 은", style: .general) == "bap eun")
    }

    @Test func cyrillicIsSpelledTheEnglishWay() {
        #expect(Romanizer.romanize("Я тебя люблю", style: .general) == "Ya tebya lyublyu")
        #expect(Romanizer.romanize("Жизнь, щастье", style: .general) == "Zhizn, shchaste")
        #expect(Romanizer.romanize("Привіт", style: .general, language: "uk") == "Pryvit")
        #expect(Romanizer.romanize("България", style: .general, language: "bg") == "Balgariya")
    }

    @Test func diacriticsAreStripped() {
        #expect(Romanizer.romanize("Καλημέρα", style: .general) == "Kalemera")
        #expect(Romanizer.romanize("コーヒー", style: .general) == "kohi")
    }

    @Test func onlyJapaneseGetsTheJapaneseReading() {
        #expect(Romanizer.style(forLanguage: "ja") == .japanese)
        #expect(Romanizer.style(forLanguage: "ja-JP") == .japanese)
        #expect(Romanizer.style(forLanguage: "zh-Hans") == .general)
        #expect(Romanizer.style(forLanguage: nil) == .general)
    }

    @Test func cjkPunctuationBecomesLatin() {
        #expect(Romanizer.tidy("aishiteru、zutto…") == "aishiteru, zutto…")
        #expect(Romanizer.tidy("wo ai ni。「hao」") == "wo ai ni. “hao”")
        #expect(Romanizer.tidy("ＡＢＣ　１２３！") == "ABC 123!")
        #expect(Romanizer.tidy("sakura ・ hana") == "sakura hana")
    }

    @Test func spacingFollowsEnglish() {
        #expect(Romanizer.tidy("kimi , boku ！") == "kimi, boku!")
        #expect(Romanizer.tidy("「 yume 」 da") == "“yume” da")
        #expect(Romanizer.tidy("  a   b  ") == "a b")
        #expect(Romanizer.tidy("3.5") == "3.5")
    }

    @Test func japaneseWordsAreSpacedAndParticlesSungAsSung() {
        let tokens: [Romanizer.Token] = [
            .init(text: "私", reading: "watashi"),
            .init(text: "は", reading: "ha"),
            .init(text: "猫", reading: "neko"),
            .init(text: "を", reading: "wo"),
            .init(text: "見", reading: "mi"),
            .init(text: "た", reading: "ta"),
            .init(text: "。"),
        ]
        #expect(Romanizer.tidy(Romanizer.joinJapanese(tokens)) == "watashi wa neko o mi ta.")
    }

    @Test func englishInsideAJapaneseLineIsKeptAsWritten() {
        let tokens: [Romanizer.Token] = [
            .init(text: "I", reading: "i"),
            .init(text: " "),
            .init(text: "don't", reading: "don't"),
            .init(text: " "),
            .init(text: "know", reading: "know"),
            .init(text: " "),
            .init(text: "君", reading: "kimi"),
            .init(text: "の", reading: "no"),
            .init(text: "Love", reading: "love"),
        ]
        #expect(Romanizer.tidy(Romanizer.joinJapanese(tokens)) == "I don't know kimi no Love")
    }

    @Test func aWordTheTokenizerCouldNotReadFallsBackToTheTransform() {
        let tokens: [Romanizer.Token] = [.init(text: "ハルカ"), .init(text: "リ", reading: "ri")]
        #expect(Romanizer.joinJapanese(tokens) == "haruka ri")
    }

    #if canImport(Darwin)
    // The system's Japanese tokenizer exists only on Apple's platforms, so these run on
    // the macOS CI runner and not on Linux.

    @Test func kanjiAreReadAsJapaneseNotMandarin() throws {
        let line = try #require(Romanizer.romanize("私は猫です", style: .japanese))
        #expect(!Romanizer.needsRomanization(line))
        #expect(line.contains("neko"))
        #expect(line.contains(" wa "))
        #expect(!line.contains("mao"))
    }

    @Test func titlesFromTheLibraryComeOutLatin() throws {
        for title in ["ハルカリノオカワリ", "×と○と罪と"] {
            let line = try #require(Romanizer.romanize(title, style: .japanese))
            #expect(!Romanizer.needsRomanization(line), "\(title) -> \(line)")
        }
        let sin = try #require(Romanizer.romanize("×と○と罪と", style: .japanese))
        #expect(sin.contains("tsumi"))
    }
    #endif
}
