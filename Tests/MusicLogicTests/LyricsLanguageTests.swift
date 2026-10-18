import Foundation
import Testing
@testable import MusicLogic

struct LyricsLanguageTests {
    @Test func serverTagsBecomeTwoLetterCodes() {
        #expect(LyricsLanguage.code(fromTag: "jpn") == "ja")
        #expect(LyricsLanguage.code(fromTag: "ENG") == "en")
        #expect(LyricsLanguage.code(fromTag: "en-US") == "en")
        #expect(LyricsLanguage.code(fromTag: "ko") == "ko")
        #expect(LyricsLanguage.code(fromTag: "chi") == "zh")
        #expect(LyricsLanguage.code(fromTag: "ger") == "de")
    }

    @Test func anUnknownTagIsNoLanguage() {
        #expect(LyricsLanguage.code(fromTag: "xxx") == nil)
        #expect(LyricsLanguage.code(fromTag: "und") == nil)
        #expect(LyricsLanguage.code(fromTag: "") == nil)
        #expect(LyricsLanguage.code(fromTag: nil) == nil)
    }

    @Test func englishIsEnglishWhateverTheRegion() {
        #expect(LyricsLanguage.isEnglish("en"))
        #expect(LyricsLanguage.isEnglish("en-GB"))
        #expect(!LyricsLanguage.isEnglish("ja"))
        #expect(!LyricsLanguage.isEnglish(nil))
    }

    @Test func kanaSettlesItAsJapanese() {
        // A recognizer can take kanji-heavy lines for Chinese; one kana is enough to know.
        let lines = ["罪と罰", "×と○と罪と"]
        #expect(LyricsLanguage.resolve(lines: lines, tag: "eng", detected: "zh-Hans") == "ja")
    }

    @Test func aStrayKanaDoesNotMakeChineseJapanese() {
        let lines = ["我の世界", "你是我的唯一", "永远爱你"]
        #expect(LyricsLanguage.resolve(lines: lines, tag: nil, detected: "zh-Hans") == "zh-Hans")
    }

    @Test func hangulSettlesItAsKorean() {
        #expect(LyricsLanguage.resolve(lines: ["사랑해", "I love you"], tag: nil, detected: "en") == "ko")
    }

    @Test func otherwiseTheRecognizerThenTheTag() {
        #expect(LyricsLanguage.resolve(lines: ["你好"], tag: "jpn", detected: "zh-Hans") == "zh-Hans")
        #expect(LyricsLanguage.resolve(lines: ["Hola"], tag: "spa", detected: nil) == "es")
        #expect(LyricsLanguage.resolve(lines: ["Hola"], tag: "xxx", detected: nil) == nil)
    }

    @Test func theEnglishChorusOfAJapaneseSongIsLeftAlone() {
        let lines = ["君の名前を呼んだ", "Baby, I love you", "", "♪", "ずっと一緒に"]
        #expect(LyricsLanguage.linesToTranslate(lines) == [0, 4])
    }

    @Test func everyLineWithWordsIsTranslatedFromALatinScript() {
        let lines = ["Te quiero", "", "♪ ♪", "Baby, I love you", "Siempre"]
        #expect(LyricsLanguage.linesToTranslate(lines) == [0, 3, 4])
    }

    @Test func aStrayWordInAnotherScriptDoesNotNarrowIt() {
        // Mostly Spanish with one word of Japanese: the Spanish still needs translating.
        let lines = ["Te quiero mucho, mi amor", "Arigato ありがとう", "Siempre conmigo"]
        #expect(LyricsLanguage.linesToTranslate(lines) == [0, 1, 2])
        #expect(LyricsLanguage.resolve(lines: lines, tag: nil, detected: "es") == "es")
    }
}
