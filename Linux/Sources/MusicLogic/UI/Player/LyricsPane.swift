import CGtk
import Foundation

/// Lyrics that follow the music: the line being sung lit and held a third of the way
/// down, the others fading with distance. Click a line to go there. Scrolling by hand
/// stops the following for four seconds, so it never fights the reader.
///
/// Romanization comes from the shared `Romanizer`; Japanese is read by the sonic service's
/// MeCab, since there is no Japanese tokenizer here, and joined as the phone joins it.
/// Translation, the phone's on-device translator there, is the service's local model
/// here: the first time a song is asked for it can take a minute or two.
@MainActor
final class LyricsPane {
    let root: Overlay
    private let env: Env
    private let lines = Box.vertical(spacing: 0)
    private let scroller: ScrolledWindow
    private let status = Bin()
    private var labels: [(line: Label, romanized: Label, translated: Label)] = []
    /// What the translation is doing, under the lines' options.
    private let translationNote = Label("", "caption", "dim").wrap().visible(false)
    private var translating: Task<Void, Never>?
    private var lyrics: StructuredLyrics?
    private var songID: String?
    private var active: Int?
    private var holdUntil: Date?
    private var animation: UnsafeMutablePointer<AdwAnimation>?

    init(env: Env) {
        self.env = env
        // The note is put back at the top of the lines on every load, after they are
        // cleared -- which let go of the last reference to it, and the next load crashed
        // on the freed label. The pane keeps one of its own.
        g_object_ref_sink(translationNote.widget)
        scroller = ScrolledWindow(Clamp(lines.margin(horizontal: 24, vertical: 120), maximum: 720)).vexpand()
        let stack = Stack()
        stack.add(scroller, name: "lyrics")
        stack.add(status, name: "status")
        root = Overlay(stack)
        root.keep(self)

        let player = env.player
        let settings = env.app.playerSettings
        let menu = MenuButton(icon: "preferences-desktop-locale-symbolic", "circular", "osd") {
            Menu([[
                .toggle("Romanize", isOn: settings.romanizesLyrics) { settings.romanizesLyrics = $0 },
                .toggle("Translate to English", isOn: settings.translatesLyrics) { settings.translatesLyrics = $0 },
            ]])
        }
        menu.halign(GTK_ALIGN_END).valign(GTK_ALIGN_START).margin(12).tooltip("Lyrics Options")
        root.add(menu)

        let reference = WeakReference(self)
        root.observe {
            let id = player.currentSong?.id
            Task { @MainActor in
                guard let pane = reference.value, pane.songID != id else { return }
                pane.songID = id
                await pane.load(stack: stack)
            }
        }
        root.observe {
            _ = player.elapsed
            reference.value?.follow()
        }
        root.observe {
            _ = settings.romanizesLyrics
            reference.value?.applyRomanization()
        }
        root.observe {
            _ = settings.translatesLyrics
            reference.value?.applyTranslation()
        }

        // Touching the scroll stops the following; it resumes four seconds later.
        let scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_VERTICAL)!
        Signal.connect(scroll, "scroll", scroll: { _, _ in
            reference.value?.holdUntil = .now.addingTimeInterval(4)
            return false
        })
        gtk_widget_add_controller(scroller.widget, scroll)
    }

    private func load(stack: Stack) async {
        guard let song = env.player.currentSong else { return }
        status.child = Spinner().size(32).halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_CENTER)
        stack.visibleName = "status"
        lines.removeAll()
        labels = []
        active = nil
        translating?.cancel()
        translationNote.isVisible = false

        var sets = await LyricsStore.shared.load(songID: song.id) ?? []
        if sets.isEmpty {
            sets = (try? await env.app.client.lyrics(songID: song.id)) ?? []
        }
        guard songID == song.id else { return }

        // A synced set first, then one in the reader's language.
        let preferred = Locale.preferredLanguages.first?.prefix(2).lowercased() ?? ""
        let synced = sets.filter(\.synced)
        lyrics = synced.first { $0.lang?.lowercased().hasPrefix(preferred) == true } ?? synced.first ?? sets.first

        guard let lyrics, !lyrics.lines.isEmpty else {
            status.child = StatusPage(icon: "format-justify-left-symbolic", title: "No Lyrics", description: "There are no lyrics for this track.")
            return
        }

        for (index, line) in lyrics.lines.enumerated() {
            let label = Label(line.value.isEmpty ? "♪" : line.value, "lyric-line").wrap()
            let romanized = Label("", "dim").wrap().visible(false)
            let translated = Label("", "lyric-translation").wrap().visible(false)
            let box = Box.vertical(spacing: 2) {
                label
                romanized
                translated
            }.margin(horizontal: 0, vertical: 8)
            if lyrics.synced, let start = line.start {
                let offset = lyrics.offset ?? 0
                box.onClick { [env] in env.player.seek(to: Double(max(0, start - offset)) / 1000) }
                gtk_widget_set_cursor_from_name(box.widget, "pointer")
            }
            _ = index
            lines.append(box)
            labels.append((label, romanized, translated))
        }
        lines.prepend(translationNote.xalign(0.5).margin(horizontal: 0, vertical: 8))
        if !lyrics.synced {
            lines.prepend(Label("Lyrics not timed", "caption", "dim").xalign(0.5).margin(horizontal: 0, vertical: 8))
            for pair in labels { pair.line.setCSS("past", true) }
        }
        stack.visibleName = "lyrics"
        scroller.scrollToTop()
        applyRomanization()
        applyTranslation()
        follow()
    }

    private func applyRomanization() {
        guard let lyrics else { return }
        let wanted = env.app.playerSettings.romanizesLyrics
        guard wanted else {
            for pair in labels { pair.romanized.isVisible = false }
            return
        }
        let text = lyrics.lines.map(\.value)
        let language = language(of: lyrics)
        let id = songID
        let sonic = SonicClient(configuration: env.app.sonic.configuration)
        let reference = WeakReference(self)
        Task { @MainActor in
            var romanized: [String?]?
            // Japanese from the service, read as the phone reads it; on its own, kanji
            // came out as Mandarin.
            if LyricsLanguage.base(of: language) == "ja", let tokens = try? await sonic.readings(text) {
                romanized = zip(text, tokens).map { line, tokens in
                    Romanizer.needsRomanization(line) ? Romanizer.romanize(tokens: tokens, line: line) : nil
                }
            }
            if romanized == nil {
                romanized = await Task.detached(priority: .userInitiated) {
                    Romanizer.romanize(text, language: language)
                }.value
            }
            guard let romanized else { return }
            guard let pane = reference.value, pane.songID == id, pane.labels.count == romanized.count else { return }
            for (pair, value) in zip(pane.labels, romanized) {
                pair.romanized.text = value ?? ""
                pair.romanized.isVisible = value != nil && pane.env.app.playerSettings.romanizesLyrics
            }
        }
    }

    /// No language recognizer here: the letters, the script and the server's tag decide.
    /// Enough for the Cyrillic spellings and for Japanese, which are what differ.
    private func language(of lyrics: StructuredLyrics) -> String? {
        let text = lyrics.lines.map(\.value)
        return LyricsLanguage.resolve(lines: text, tag: lyrics.lang, detected: LyricsLanguage.guess(text))
    }

    /// Each line's English beneath it, from the sonic service, kept on this computer once
    /// made. Only lyrics not in English, and only the lines that need it.
    private func applyTranslation() {
        translating?.cancel()
        guard let lyrics, let id = songID else { return }
        guard env.app.playerSettings.translatesLyrics else {
            for pair in labels { pair.translated.isVisible = false }
            translationNote.isVisible = false
            return
        }
        let text = lyrics.lines.map(\.value)
        let language = language(of: lyrics)
        let wanted = LyricsLanguage.linesToTranslate(text)
        guard !LyricsLanguage.isEnglish(language), !wanted.isEmpty else {
            for pair in labels { pair.translated.isVisible = false }
            translationNote.isVisible = false
            return
        }
        let sonic = SonicClient(configuration: env.app.sonic.configuration)
        let reference = WeakReference(self)
        translating = Task { @MainActor in
            @MainActor func show(_ translations: [String?]) {
                guard let pane = reference.value, pane.songID == id, pane.labels.count == translations.count else { return }
                for (pair, english) in zip(pane.labels, translations) {
                    pair.translated.text = english ?? ""
                    pair.translated.isVisible = english != nil
                }
                pane.translationNote.isVisible = false
            }
            @MainActor func say(_ note: String) {
                guard let pane = reference.value, pane.songID == id else { return }
                pane.translationNote.text = note
                pane.translationNote.isVisible = true
            }
            if let kept = await LyricTranslationStore.shared.translations(songID: id, lines: text) {
                return show(kept)
            }
            let source = wanted.map { text[$0] }
            say("Translating…")
            // Asked again every few seconds while the service works on it, for up to
            // five minutes.
            for attempt in 0..<75 {
                guard !Task.isCancelled else { return }
                do {
                    switch try await sonic.translate(source, language: language ?? "") {
                    case let .done(english, draft):
                        var translations = [String?](repeating: nil, count: text.count)
                        for (index, line) in zip(wanted, english) where line != text[index] { translations[index] = line }
                        show(translations)
                        guard draft else {
                            await LyricTranslationStore.shared.save(translations, of: text, songID: id)
                            return
                        }
                        // A draft is shown and not kept; the better one replaces it when it
                        // comes, here if it is soon, or the next time these lyrics open.
                        say("A quick translation for now: a better one is on its way.")
                        try? await Task.sleep(for: .seconds(5))
                    case .translating:
                        if attempt == 3 { say("Translating… The first time takes a minute or two.") }
                        try? await Task.sleep(for: .seconds(4))
                    case let .failed(reason):
                        return say("Couldn't translate these lyrics: \(reason)")
                    }
                } catch {
                    return say("Couldn't reach the translator.")
                }
            }
            say("The translation is taking too long. Try again later.")
        }
    }

    /// Binary search for the line being sung, then highlight and scroll only when it moved.
    private func follow() {
        guard let lyrics, lyrics.synced, !labels.isEmpty else { return }
        // A positive offset brings the lines *sooner* (OpenSubsonic, from LRC's
        // `[offset:]`), so the clock runs ahead by it; subtracting made it come later.
        let now = Int(env.player.elapsed * 1000) + (lyrics.offset ?? 0)
        let starts = lyrics.lines.map { $0.start ?? 0 }
        var low = 0
        var high = starts.count - 1
        var found: Int?
        while low <= high {
            let middle = (low + high) / 2
            if starts[middle] <= now {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        guard found != active else { return }
        active = found
        for (index, pair) in labels.enumerated() {
            pair.line.setCSS("current", index == found)
            pair.line.setCSS("past", found.map { index < $0 } ?? false)
        }
        guard let found, holdUntil.map({ $0 < .now }) ?? true else { return }
        scroll(to: found)
    }

    private func scroll(to index: Int) {
        guard index < labels.count else { return }
        var point = graphene_point_t(x: 0, y: 0)
        var result = graphene_point_t(x: 0, y: 0)
        guard gtk_widget_compute_point(labels[index].line.widget, lines.widget, &point, &result) != 0 else { return }
        let adjustment = scroller.verticalAdjustment
        let page = gtk_adjustment_get_page_size(adjustment)
        let target = max(0, Double(result.y) + 120 - page * 0.32)
        let from = gtk_adjustment_get_value(adjustment)

        if let animation {
            adw_animation_skip(animation)
            g_object_unref(animation.rawPointer)
        }
        let target_ = adw_callback_animation_target_new({ value, data in
            guard let data else { return }
            gtk_adjustment_set_value(data.assumingMemoryBound(to: GtkAdjustment.self), value)
        }, UnsafeMutableRawPointer(adjustment), nil)
        let made = adw_timed_animation_new(scroller.widget, from, target, 400, target_)
        animation = made
        if let made { adw_animation_play(made) }
    }
}
