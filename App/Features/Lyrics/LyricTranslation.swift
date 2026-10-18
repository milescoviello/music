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
    private(set) var status: Status = .idle
    /// Non-nil starts the translation task; a new value starts it again.
    private(set) var configuration: TranslationSession.Configuration?

    @ObservationIgnored private var job: Job?
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

    /// A new song's lyrics. A translation made before is shown straight away.
    func prepare(songID: String, lines: [String], language: String?, wanted: Bool) async {
        let job = Job(songID: songID, lines: lines)
        self.job = job
        self.language = language
        self.lines = []
        status = .idle
        configuration = nil

        if let cached = await LyricTranslationStore.shared.translations(songID: songID, lines: lines),
           self.job == job {
            self.lines = cached
        }
        if wanted { await start() }
    }

    /// The toggle. Turning it off part-way stops the translation; one already made is
    /// kept, so turning it back on is instant. Turning it off and on again after a
    /// failure tries again.
    func setWanted(_ wanted: Bool) async {
        if wanted {
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

        let source = language.map { Locale.Language(identifier: $0) }
        if let source, let language, await !Self.canTranslate(from: source) {
            guard self.job == job, status == .translating else { return }
            let name = Locale.current.localizedString(forIdentifier: language) ?? language
            status = .failed("Translation from \(name) isn't available")
            return
        }
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

    private func finish(_ job: Job, with translations: [String?]) {
        Task { await LyricTranslationStore.shared.save(translations, of: job.lines, songID: job.songID) }
        guard job == self.job else { return }
        lines = translations
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
