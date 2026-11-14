import Foundation
import Observation
import Translation

/// The English under each line of the lyrics, translated on the phone by Apple's
/// Translation framework. Nothing leaves the device; the first time a language is used,
/// the system asks to download it.
///
/// The lyrics screen hands this each song's lines. When translation is wanted it sets
/// `configuration`, which starts the screen's `.translationTask`, whose closure is
/// `run(_:for:)`.
@MainActor
@Observable
final class LyricTranslation {
    /// A song's lines, as asked for. A result for a song no longer showing is kept for
    /// next time but not shown.
    struct Job: Equatable, Sendable {
        let songID: String
        let lines: [String]
    }

    enum Status: Equatable {
        case idle
        case translating
        case failed(String)
    }

    /// The translation by line index; nil where there is nothing to show under a line.
    /// Empty until translated.
    private(set) var lines: [String?] = []
    /// A short note under a translated line, where the words carry wordplay or an idiom
    /// the English can't; nil for most. Only the server's whole-song translations have them.
    private(set) var notes: [String?] = []

    /// Asks the music server for the song's whole-song translation (Flash-Next, made ahead
    /// of time), given the lines asked about and their language: one answer per line, or
    /// nil when it has none. Set by the lyrics screen; without it, the phone translates.
    typealias Server = @Sendable (_ lines: [String], _ language: String) async -> SonicClient.Translated?
    private(set) var status: Status = .idle
    /// Non-nil starts the translation task; a new value starts it again.
    private(set) var configuration: TranslationSession.Configuration?

    @ObservationIgnored private var job: Job?
    @ObservationIgnored private var server: Server?
    /// What made the translation on screen ("flash-next" for the server's whole-song one).
    @ObservationIgnored private var engine: String?
    /// What the lyrics are in, as `LyricsLanguage.resolve` gave it: "ja", "zh-Hans".
    @ObservationIgnored private var language: String?
    @ObservationIgnored private var lastConfiguration: TranslationSession.Configuration?

    /// A note for the top of the lyrics.
    var note: String? {
        switch status {
        case .idle: return nil
        case .translating: return "Translating…"
        case .failed(let reason): return reason
        }
    }

    /// A new song's lyrics. A translation made before is shown straight away; one made on
    /// the phone gives way to the server's whole-song translation once there is one.
    func prepare(songID: String, lines: [String], language: String?, wanted: Bool, server: Server? = nil) async {
        let job = Job(songID: songID, lines: lines)
        self.job = job
        self.language = language
        self.server = server
        self.lines = []
        self.notes = []
        self.engine = nil
        status = .idle
        configuration = nil

        let kept = await LyricTranslationStore.shared.kept(songID: songID, lines: lines)
        log("\(songID): \(lines.count) lines in \(language ?? "an unknown language"), Translate to English \(wanted ? "on" : "off"), "
            + (kept.map { "a kept translation by \($0.engine ?? "the phone")\($0.isFinal ? "" : ", not final")" } ?? "no kept translation"))
        if let kept, self.job == job {
            self.lines = kept.translations
            self.notes = kept.notes
            self.engine = kept.engine
            if !kept.isFinal, wanted { await upgrade(job) }
        }
        if wanted { await start() }
    }

    /// The server's whole-song translation in place of one kept from the phone, if it has one.
    private func upgrade(_ job: Job) async {
        guard let made = await fromServer(job), self.job == job else { return }
        finish(job, with: made.lines, notes: made.notes, engine: LyricTranslationStore.wholeSong)
    }

    /// The server's whole-song translation of the lines worth translating, placed by line.
    private func fromServer(_ job: Job) async -> (lines: [String?], notes: [String?])? {
        guard let server else { log("\(job.songID): no server to ask for a translation"); return nil }
        guard let language, !LyricsLanguage.isEnglish(language) else {
            log("\(job.songID): lyrics in \(language ?? "an unknown language"), no translation asked")
            return nil
        }
        let wanted = LyricsLanguage.linesToTranslate(job.lines)
        guard !wanted.isEmpty else { log("\(job.songID): no lines worth translating"); return nil }
        let asked = Date()
        guard let answer = await server(wanted.map { job.lines[$0] }, language) else {
            log("\(job.songID): no whole-song translation from the server for \(wanted.count) \(language) lines (\(Self.took(asked)))")
            return nil
        }
        guard answer.isWholeSong else {
            log("\(job.songID): the server answered with \(answer.engine ?? "an unnamed engine"), not a whole-song translation; not used")
            return nil
        }
        guard answer.lines.count == wanted.count else {
            log("\(job.songID): the server's translation has \(answer.lines.count) lines for \(wanted.count) asked; not used")
            return nil
        }
        log("\(job.songID): whole-song translation by \(answer.engine ?? "?"): \(wanted.count) lines, "
            + "\(answer.notes.compactMap { $0 }.count) notes (\(Self.took(asked)))")
        var lines = [String?](repeating: nil, count: job.lines.count)
        var notes = [String?](repeating: nil, count: job.lines.count)
        for (k, index) in wanted.enumerated() {
            lines[index] = Self.shown(answer.lines[k], for: job.lines[index])
            notes[index] = lines[index] == nil ? nil : answer.notes[k]
        }
        return (lines, notes)
    }

    /// The toggle. Turning it off part-way stops the translation; one already made is
    /// kept, so turning it back on is instant. Turning it off and on again after a
    /// failure tries again.
    func setWanted(_ wanted: Bool) async {
        if let job { log("\(job.songID): Translate to English \(wanted ? "on" : "off")") }
        if wanted {
            if let job, !lines.isEmpty, !LyricTranslationStore.isWholeSong(engine) { await upgrade(job) }
            await start()
        } else if status != .idle {
            status = .idle
            configuration = nil
        }
    }

    private func start() async {
        guard let job, lines.isEmpty, status == .idle,
              !LyricsLanguage.isEnglish(language),
              !LyricsLanguage.linesToTranslate(job.lines).isEmpty
        else { return }
        status = .translating

        // The server's whole-song translation first: made with the whole song in view by a
        // far bigger model than the phone's, and with notes. The phone's own when it has none.
        if let made = await fromServer(job) {
            guard self.job == job, status == .translating else { return }
            return finish(job, with: made.lines, notes: made.notes, engine: LyricTranslationStore.wholeSong)
        }
        guard self.job == job, status == .translating else { return }

        let source = language.map { Locale.Language(identifier: $0) }
        if let source, let language, await !Self.canTranslate(from: source) {
            guard self.job == job, status == .translating else { return }
            let name = Locale.current.localizedString(forIdentifier: language) ?? language
            log("\(job.songID): no whole-song translation, and the phone can't translate from \(name)")
            status = .failed("Translation from \(name) isn't available")
            return
        }
        log("\(job.songID): no whole-song translation; translating \(LyricsLanguage.linesToTranslate(job.lines).count) lines on the phone")
        guard self.job == job, status == .translating else { return }

        // An equal configuration would not start the task again, as it must for the
        // next song in the same language.
        var configuration = TranslationSession.Configuration(
            source: source,
            target: Locale.Language(identifier: "en")
        )
        if configuration == lastConfiguration { configuration.invalidate() }
        lastConfiguration = configuration
        self.configuration = configuration
    }

    /// The task's question: what to translate, if anything.
    private var pendingJob: Job? {
        status == .translating ? job : nil
    }

    /// What the translation did, in the logs he can send ("[lyrics]").
    private func log(_ message: String) {
        Task { await Diagnostics.shared.record("lyrics", message) }
    }

    private static func took(_ since: Date) -> String {
        String(format: "%.1fs", Date().timeIntervalSince(since))
    }

    private func finish(_ job: Job, with translations: [String?], notes: [String?]? = nil, engine: String? = nil) {
        Task { await LyricTranslationStore.shared.save(translations, notes: notes, engine: engine, of: job.lines, songID: job.songID) }
        guard job == self.job else { return }
        lines = translations
        self.notes = notes ?? []
        self.engine = engine
        status = .idle
    }

    private func fail(_ job: Job, _ error: any Error, cancelled: Bool) {
        guard job == self.job, status == .translating else { return }
        // Cancelled is not failed: the screen went or the toggle was turned off, and the
        // next attempt should simply try again.
        if cancelled {
            status = .idle
            return
        }
        log("\(job.songID): the phone's translation failed: \(error.localizedDescription)")
        status = .failed((error as? LocalizedError)?.errorDescription ?? "Couldn't translate these lyrics")
    }

    // MARK: - The translation task

    /// The whole of the `.translationTask` closure, which must be `@Sendable`:
    ///
    ///     .translationTask(translation.configuration) { @Sendable [translation] session in
    ///         await LyricTranslation.run(session, for: translation)
    ///     }
    ///
    /// Nonisolated, so the session stays on the task it was given to. A closure isolated
    /// to the main actor, as a view's are, would have to send it off the main actor to
    /// translate, which strict concurrency rejects as a data race.
    nonisolated static func run(_ session: TranslationSession, for translation: LyricTranslation) async {
        guard let job = await translation.pendingJob else { return }
        do {
            let lines = try await translate(job.lines, with: session)
            await translation.finish(job, with: lines)
        } catch {
            await translation.fail(job, error, cancelled: Task.isCancelled || error is CancellationError)
        }
    }

    /// The lines worth translating, all in one request to the session.
    private nonisolated static func translate(_ lines: [String], with session: TranslationSession) async throws -> [String?] {
        var result = [String?](repeating: nil, count: lines.count)
        let requests = LyricsLanguage.linesToTranslate(lines).map { index in
            TranslationSession.Request(sourceText: lines[index], clientIdentifier: String(index))
        }
        guard !requests.isEmpty else { return result }

        for response in try await session.translations(from: requests) {
            guard let id = response.clientIdentifier, let index = Int(id), result.indices.contains(index) else {
                continue
            }
            result[index] = shown(response.targetText, for: lines[index])
        }
        return result
    }

    /// A translation worth showing under its line, or nil when it would only repeat it:
    /// a name, "la la la", a phrase in English already.
    private nonisolated static func shown(_ translated: String, for original: String) -> String? {
        let trimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, comparable(trimmed) != comparable(original) else { return nil }
        return trimmed
    }

    private nonisolated static func comparable(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Asked up front, so a language the framework cannot translate is a note on the
    /// screen rather than an error from the task.
    private nonisolated static func canTranslate(from source: Locale.Language) async -> Bool {
        let status = await LanguageAvailability().status(from: source, to: Locale.Language(identifier: "en"))
        return status != .unsupported
    }
}
