import CGtk
import Foundation

/// Lyrics that follow the music: the line being sung lit and held a third of the way
/// down, the others fading with distance. Click a line to go there. Scrolling by hand
/// stops the following for four seconds, so it never fights the reader.
///
/// Fix Lyrics, in the options, fixes them by hand as the phone does (`LyricsTiming`):
/// every line moved at once, each line given the moment it starts, a line's words changed
/// or the line taken out (right-click), then saved into the song's file on the server.
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
    private var labels: [(line: Label, romanized: Label, translated: Label, note: Label, time: Label)] = []
    private let stack: Stack
    /// What the translation is doing, under the lines' options.
    private let translationNote = Label("", "caption", "dim").wrap().visible(false)
    private var translating: Task<Void, Never>?
    private var lyrics: StructuredLyrics?
    private var songID: String?
    private var active: Int?
    private var holdUntil: Date?
    private var animation: UnsafeMutablePointer<AdwAnimation>?

    /// Word by word (`WordTiming`): each line's words and when each is sung, and the line
    /// whose words are lighting up now, redrawn as they are sung.
    private var cues: [Int: [WordCue]] = [:]
    private var wordTask: Task<Void, Never>?
    private var wordLine: Int?

    // Timing by hand. The song stays the one being timed while the next plays, so one
    // timed to its last line can still be saved.
    private var timing: LyricsTiming?
    private var timingSongID: String?
    private var isSaving = false
    private let timingBar = Box.vertical(spacing: 10)
    private let timingNote = Label("", "caption").wrap()
    private let timingError = Label("", "caption", "error").wrap()
    private let shiftLabel = Label("", "caption", "numeric")
    private let progressLabel = Label("", "caption", "dim", "numeric")
    private let nudges: [Button]
    private let nowButton = Button("Line Starts Now", "suggested-action")
    private let undoButton = Button(icon: "edit-undo-symbolic", "flat")
    private let saveButton = Button("Save", "suggested-action")
    private let cancelButton = Button("Cancel", "flat")

    init(env: Env) {
        self.env = env
        // The note is put back at the top of the lines on every load, after they are
        // cleared -- which let go of the last reference to it, and the next load crashed
        // on the freed label. The pane keeps one of its own.
        g_object_ref_sink(translationNote.widget)
        scroller = ScrolledWindow(Clamp(lines.margin(horizontal: 24, vertical: 120), maximum: 720)).vexpand()
        let stack = Stack()
        self.stack = stack
        nudges = [(-500, "−0.5"), (-100, "−0.1"), (100, "+0.1"), (500, "+0.5")].map { milliseconds, title in
            Button(title, "flat").tooltip(milliseconds > 0 ? "Every line \(title.dropFirst()) s later" : "Every line \(title.dropFirst()) s sooner")
        }
        stack.add(scroller, name: "lyrics")
        stack.add(status, name: "status")
        // The timing controls under the lyrics rather than over them: the lyrics pane can
        // be the size of the cover, and they hid half of it.
        let bar = timingBar
        root = Overlay(Box.vertical(spacing: 0) {
            stack
            bar
        })
        root.keep(self)

        let player = env.player
        let settings = env.app.playerSettings
        let reference = WeakReference(self)
        let menu = MenuButton(icon: "preferences-desktop-locale-symbolic", "circular", "osd") {
            Menu([
                [.action("Fix Lyrics", enabled: reference.value?.loadedID != nil) { reference.value?.startTiming() }],
                [
                    .toggle("Romanize", isOn: settings.romanizesLyrics) { settings.romanizesLyrics = $0 },
                    .toggle("Translate to English", isOn: settings.translatesLyrics) { settings.translatesLyrics = $0 },
                ],
            ])
        }
        menu.halign(GTK_ALIGN_END).valign(GTK_ALIGN_START).margin(12).tooltip("Lyrics Options")
        root.add(menu)
        self.menu = menu
        buildTimingBar()

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

        // Loaded while hidden behind the cover, the lyrics had nowhere to scroll to, and
        // opened at the top with the line being sung out of sight.
        Signal.connect(scroller.widget, "map") {
            guard let pane = reference.value, let index = pane.timing?.next ?? pane.active else { return }
            pane.scrollOnceLaidOut(to: index)
        }

        // Touching the scroll stops the following; it resumes four seconds later.
        let scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_VERTICAL)!
        Signal.connect(scroll, "scroll", scroll: { _, _ in
            reference.value?.holdUntil = .now.addingTimeInterval(4)
            return false
        })
        gtk_widget_add_controller(scroller.widget, scroll)
    }

    private var menu: MenuButton?
    /// The song whose lyrics are on screen; nil while they load. Not `songID`, which
    /// changes a moment before the lyrics do.
    private var loadedID: String?
    /// Whether the timing bar last said the song being timed was playing.
    private var timingShowedPlaying: Bool?

    /// `showing`: lyrics just saved, shown as they are -- the server has them only once
    /// its watcher has scanned the folder again.
    private func load(stack: Stack, showing saved: StructuredLyrics? = nil) async {
        // A song being timed by hand stays on screen when the next one starts.
        guard timing == nil else { return }
        guard let song = env.player.currentSong else { return }
        loadedID = nil
        status.child = Spinner().size(32).halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_CENTER)
        stack.visibleName = "status"
        lines.removeAll()
        labels = []
        active = nil
        stopWords()
        cues = [:]
        translating?.cancel()
        translationNote.isVisible = false

        // A downloaded song's own copy, checked against the server once it is on screen.
        var kept: [StructuredLyrics] = []
        if let saved {
            lyrics = saved
        } else {
            var sets = await LyricsStore.shared.load(songID: song.id) ?? []
            kept = sets
            if sets.isEmpty {
                sets = (try? await env.app.client.lyrics(songID: song.id)) ?? []
            }
            guard songID == song.id, timing == nil else { return }

            // A synced set first, then one in the reader's language.
            let preferred = Locale.preferredLanguages.first?.prefix(2).lowercased() ?? ""
            let synced = sets.filter(\.synced)
            lyrics = synced.first { $0.lang?.lowercased().hasPrefix(preferred) == true } ?? synced.first ?? sets.first
        }

        guard let lyrics, !lyrics.lines.isEmpty else {
            showMissing(stack: stack, songID: song.id)
            return
        }

        showLines(lyrics.lines, clickable: lyrics.synced)
        lines.prepend(translationNote.xalign(0.5).margin(horizontal: 0, vertical: 8))
        if !lyrics.synced {
            lines.prepend(Label("Lyrics not timed", "caption", "dim").xalign(0.5).margin(horizontal: 0, vertical: 8))
            for pair in labels { pair.line.setCSS("past", true) }
        }
        stack.visibleName = "lyrics"
        loadedID = song.id
        scroller.scrollToTop()
        applyRomanization()
        applyTranslation()
        follow()
        // The lines are not laid out yet, so `follow` could not bring the one being sung
        // into view, and it only tries again when the line changes: paused, the view
        // stayed at the top with the line out of sight.
        if let active { scrollOnceLaidOut(to: active) }
        if lyrics.synced { loadWords(for: song.id, lyrics: lyrics) }
        if !kept.isEmpty { await refreshKept(kept, songID: song.id, stack: stack) }
    }

    /// A downloaded song's lyrics come from the copy saved with it, at once and offline
    /// too; online, the server is asked as well. Lyrics fixed or retimed since the download
    /// take the saved copy's place and come on screen (the phone's `refreshKept`).
    private func refreshKept(_ kept: [StructuredLyrics], songID id: String, stack: Stack) async {
        let server = try? await env.app.client.lyrics(songID: id)
        guard let fresh = LyricsStore.update(kept: kept, server: server) else { return }
        await LyricsStore.shared.save(fresh, for: id)
        // Not over a song moved on from, or one being timed by hand.
        guard loadedID == id, songID == id, timing == nil else { return }
        await load(stack: stack)
    }

    // MARK: - Word by word

    private func loadWords(for id: String, lyrics: StructuredLyrics) {
        // Where each line is sung: its stamp less the set's offset (`follow`).
        let offset = lyrics.offset ?? 0
        let sung = lyrics.lines.map { LyricLine(start: $0.start.map { $0 - offset }, value: $0.value) }
        let configuration = env.app.sonic.configuration
        let reference = WeakReference(self)
        Task { @MainActor in
            guard let pane = reference.value else { return }
            let found = await pane.env.app.wordTimings.cues(for: id, lines: sung, sonic: configuration)
            guard let pane = reference.value, pane.loadedID == id, pane.timing == nil else { return }
            pane.cues = found
            pane.active = nil
            pane.follow()
        }
    }

    /// The line `index` lights up word by word while it is the one sung, if it can.
    private func startWords(on index: Int?) {
        stopWords()
        guard let index, let words = cues[index], let lyrics, index < labels.count,
              let start = lyrics.lines[index].start else { return }
        wordLine = index
        let label = labels[index].line
        let offset = lyrics.offset ?? 0
        let reference = WeakReference(self)
        wordTask = Task { @MainActor in
            var shown = -1
            while !Task.isCancelled {
                guard let pane = reference.value else { return }
                let into = Int(pane.env.player.elapsedNow * 1000) + offset - start
                let count = WordTiming.sung(words, at: into)
                if count != shown {
                    shown = count
                    let done = words.prefix(count).map(\.text).joined()
                    let rest = words.dropFirst(count).map(\.text).joined()
                    label.setMarkup("\(Markup.escape(done))<span alpha=\"45%\">\(Markup.escape(rest))</span>")
                }
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }

    private func stopWords() {
        wordTask?.cancel()
        wordTask = nil
        if let wordLine, wordLine < labels.count, let lyrics, wordLine < lyrics.lines.count {
            let value = lyrics.lines[wordLine].value
            labels[wordLine].line.text = value.isEmpty ? "♪" : value
        }
        wordLine = nil
    }

    /// No lyrics, and a way to find some: LRCLIB, through the service, which saves what it
    /// finds beside the song.
    private func showMissing(stack: Stack, songID: String) {
        let find = Button("Find Lyrics", "suggested-action", "pill").halign(GTK_ALIGN_CENTER)
        let page = StatusPage(
            icon: "format-justify-left-symbolic", title: "No Lyrics",
            description: "There are no lyrics for this track.", child: find
        )
        status.child = page
        let reference = WeakReference(self)
        find.onClicked { [env] in
            find.isSensitive = false
            page.descriptionText = "Looking on LRCLIB…"
            Task { @MainActor in
                let said: String
                do {
                    switch try await env.app.findLyrics(songID: songID) {
                    case let .found(lyrics):
                        guard let pane = reference.value, pane.songID == songID else { return }
                        await pane.load(stack: stack, showing: lyrics)
                        return
                    case .notFound: said = "LRCLIB has no lyrics for this recording."
                    case .instrumental: said = "LRCLIB lists this song as instrumental."
                    }
                } catch {
                    said = error.localizedDescription
                }
                guard reference.value?.songID == songID else { return }
                page.descriptionText = said
                find.isSensitive = true
            }
        }
    }

    /// A row for each line. A click goes to the line, or while timing marks it.
    private func showLines(_ shown: [LyricLine], clickable: Bool) {
        let reference = WeakReference(self)
        for (index, line) in shown.enumerated() {
            let label = Label(line.value.isEmpty ? "♪" : line.value, "lyric-line").wrap()
            let romanized = Label("", "dim").wrap().visible(false)
            let translated = Label("", "lyric-translation").wrap().visible(false)
            let note = Label("", "lyric-note").wrap().visible(false)
            let time = Label("", "caption", "dim", "numeric").visible(false)
            let box = Box.vertical(spacing: 2) {
                label
                romanized
                translated
                note
                time
            }.margin(horizontal: 0, vertical: 8)
            if clickable {
                box.onClick { reference.value?.clicked(index) }
                gtk_widget_set_cursor_from_name(box.widget, "pointer")
            }
            // While fixing them: a line's words, or the line itself.
            box.contextMenu { reference.value?.lineMenu(index) }
            lines.append(box)
            labels.append((label, romanized, translated, note, time))
        }
    }

    private func clicked(_ index: Int) {
        if timing != nil { return markLine(index) }
        guard let lyrics, lyrics.synced, lyrics.lines.indices.contains(index), let start = lyrics.lines[index].start else { return }
        // Sung `offset` ms sooner than its stamp: see `follow`.
        env.player.seek(to: Double(max(0, start - (lyrics.offset ?? 0))) / 1000)
    }

    private func applyRomanization() {
        guard timing == nil, let lyrics else { return }
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
    /// made. Only lyrics not in English, and only the lines that need it. A whole-song
    /// translation made ahead of time on the server (Flash-Next, with notes under the lines
    /// that need them) replaces any other kept here.
    private func applyTranslation() {
        translating?.cancel()
        guard timing == nil, let lyrics, let id = songID else { return }
        guard env.app.playerSettings.translatesLyrics else {
            for pair in labels { pair.translated.isVisible = false; pair.note.isVisible = false }
            translationNote.isVisible = false
            return
        }
        let text = lyrics.lines.map(\.value)
        let language = language(of: lyrics)
        let wanted = LyricsLanguage.linesToTranslate(text)
        guard !LyricsLanguage.isEnglish(language), !wanted.isEmpty else {
            for pair in labels { pair.translated.isVisible = false; pair.note.isVisible = false }
            translationNote.isVisible = false
            return
        }
        let sonic = SonicClient(configuration: env.app.sonic.configuration)
        let reference = WeakReference(self)
        translating = Task { @MainActor in
            @MainActor func show(_ translations: [String?], _ notes: [String?]) {
                guard let pane = reference.value, pane.songID == id, pane.labels.count == translations.count else { return }
                for (index, (pair, english)) in zip(pane.labels, translations).enumerated() {
                    pair.translated.text = english ?? ""
                    pair.translated.isVisible = english != nil
                    let note = english == nil ? nil : (notes.indices.contains(index) ? notes[index] : nil)
                    pair.note.text = note ?? ""
                    pair.note.isVisible = note != nil
                }
                pane.translationNote.isVisible = false
            }
            @MainActor func say(_ note: String) {
                guard let pane = reference.value, pane.songID == id else { return }
                pane.translationNote.text = note
                pane.translationNote.isVisible = true
            }
            /// Placed by line: each answer is for `wanted`, the lines asked about.
            func placed(_ answer: SonicClient.Translated) -> (lines: [String?], notes: [String?]) {
                var translations = [String?](repeating: nil, count: text.count)
                var notes = [String?](repeating: nil, count: text.count)
                for (k, index) in wanted.enumerated() where k < answer.lines.count {
                    guard answer.lines[k] != text[index] else { continue }
                    translations[index] = answer.lines[k]
                    notes[index] = answer.notes.indices.contains(k) ? answer.notes[k] : nil
                }
                return (translations, notes)
            }
            let source = wanted.map { text[$0] }
            if let kept = await LyricTranslationStore.shared.kept(songID: id, lines: text) {
                show(kept.translations, kept.notes)
                guard !kept.isFinal else { return }
                // Kept from before the whole-song translations: one quiet ask for a better one.
                if case let .done(answer)? = try? await sonic.translate(source, language: language ?? "", songID: id),
                   answer.isWholeSong, !Task.isCancelled {
                    let made = placed(answer)
                    show(made.lines, made.notes)
                    await LyricTranslationStore.shared.save(made.lines, notes: made.notes, engine: answer.engine, of: text, songID: id)
                }
                return
            }
            say("Translating…")
            // Asked again every few seconds while the service works on it, for up to
            // five minutes.
            for attempt in 0..<75 {
                guard !Task.isCancelled else { return }
                do {
                    switch try await sonic.translate(source, language: language ?? "", songID: id) {
                    case let .done(answer):
                        let made = placed(answer)
                        show(made.lines, made.notes)
                        guard answer.draft else {
                            await LyricTranslationStore.shared.save(made.lines, notes: made.notes, engine: answer.engine, of: text, songID: id)
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
        if timing != nil { return followTiming() }
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
        startWords(on: found)
        guard let found, holdUntil.map({ $0 < .now }) ?? true else { return }
        scroll(to: found)
    }

    // MARK: - Timing by hand

    private func buildTimingBar() {
        let reference = WeakReference(self)
        for (button, milliseconds) in zip(nudges, [-500, -100, 100, 500]) {
            button.onClicked { reference.value?.change { $0.nudge(by: milliseconds) } }
        }
        nowButton.onClicked {
            guard let pane = reference.value else { return }
            let now = Int((pane.env.player.elapsedNow * 1000).rounded())
            pane.change { $0.timeNext(at: now) }
        }
        undoButton.tooltip("Undo").onClicked { reference.value?.change { $0.undo() } }
        saveButton.onClicked { reference.value?.save() }
        cancelButton.onClicked { reference.value?.endTiming(saved: nil) }

        let shiftRow = Box.horizontal(spacing: 4) {
            nudges[0]
            nudges[1]
            shiftLabel.hexpand().xalign(0.5)
            nudges[2]
            nudges[3]
        }
        // Narrow enough for a pane the size of the cover.
        let actions = Box.horizontal(spacing: 8) {
            undoButton
            nowButton.hexpand()
            saveButton
        }
        timingBar.append(Box.horizontal(spacing: 8) {
            timingNote.hexpand().xalign(0)
            progressLabel
            cancelButton
        })
        timingBar.append(timingError.xalign(0).visible(false))
        timingBar.append(shiftRow)
        timingBar.append(actions)
        timingBar.setCSS("lyrics-timing", true)
        timingBar.margin(horizontal: 8, vertical: 8)
        timingBar.valign(GTK_ALIGN_END).visible(false)
    }

    private func startTiming() {
        guard timing == nil, let lyrics, let id = loadedID else { return }
        var made = LyricsTiming(lyrics)
        if made.wasSynced {
            // The line after the one being sung: the next to come.
            let current = LyricsTiming.current(at: Int(env.player.elapsedNow * 1000), in: made.lines)
            made.mark(made.lines.indices.first { $0 > (current ?? -1) && !made.lines[$0].value.isEmpty })
        }
        stopWords()
        timing = made
        timingSongID = id
        timingShowedPlaying = nil
        translating?.cancel()
        translationNote.isVisible = false
        timingError.isVisible = false
        lines.removeAll()
        labels = []
        active = nil
        holdUntil = nil
        showLines(made.lines, clickable: true)
        timingBar.isVisible = true
        menu?.isVisible = false
        refreshTiming()
        followTiming()
        if let next = made.next { scrollOnceLaidOut(to: next) }
    }

    /// Lines just made have no place yet to scroll to: once GTK has laid them out.
    private func scrollOnceLaidOut(to index: Int) {
        let reference = WeakReference(self)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            reference.value?.scroll(to: index)
        }
    }

    /// One change to the timing, then everything that shows it.
    private func change(_ edit: (inout LyricsTiming) -> Void) {
        guard var current = timing else { return }
        let marked = current.next
        edit(&current)
        timing = current
        // A line taken out, or put back by Undo: the rows again. Words changed: the text.
        if current.lines.count != labels.count {
            lines.removeAll()
            labels = []
            showLines(current.lines, clickable: true)
        } else {
            for (pair, line) in zip(labels, current.lines) { pair.line.text = line.value.isEmpty ? "♪" : line.value }
        }
        timingError.isVisible = false
        refreshTiming()
        active = nil
        followTiming()
        if let next = current.next, next != marked, holdUntil.map({ $0 < .now }) ?? true { scroll(to: next) }
    }

    private func lineMenu(_ index: Int) -> Menu? {
        guard let timing, timing.lines.indices.contains(index) else { return nil }
        let reference = WeakReference(self)
        let words = timing.lines[index].value
        return Menu([[
            .action("Edit Words…") {
                Dialogs.prompt("Edit Line", text: words, confirm: "Done") { edited in
                    reference.value?.change { $0.edit(index, to: edited) }
                }
            },
            .action("Delete Line", destructive: true, enabled: timing.lines.count > 1) {
                reference.value?.change { $0.delete(index) }
            },
        ]])
    }

    private func markLine(_ index: Int) {
        change { $0.mark(index) }
        // A line with a time plays from a moment before it, to time as it comes.
        guard showsPlayingSong, let start = timing?.lines[index].start else { return }
        env.player.seek(to: Double(max(0, start - 3000)) / 1000)
    }

    /// Whether the lines are of the song playing: not once a song being timed has ended.
    private var showsPlayingSong: Bool { timing == nil || timingSongID == env.player.currentSong?.id }

    private func refreshTiming() {
        guard let timing else { return }
        for (index, pair) in labels.enumerated() where index < timing.lines.count {
            pair.time.text = timing.lines[index].start.map(Self.stamp) ?? "Not timed"
            pair.time.isVisible = true
            pair.line.setCSS("lyric-marked", timing.next == index)
        }
        shiftLabel.text = Self.shiftText(timing.shift)
        progressLabel.text = timing.isTimed && !timing.isComplete ? "\(timing.timedCount) of \(timing.lines.count) timed" : ""
        timingNote.text = showsPlayingSong
            ? "Click a line to time it, right-click to change its words"
            : "This song has ended. Save, or play it again to keep timing."
        for button in nudges { button.isSensitive = timing.isTimed && !isSaving }
        nowButton.label = timing.next == nil ? "Every Line Timed" : "Line Starts Now"
        nowButton.isSensitive = timing.next != nil && showsPlayingSong && !isSaving
        undoButton.isSensitive = timing.canUndo && !isSaving
        saveButton.isSensitive = timing.canSave && !isSaving
        cancelButton.isSensitive = !isSaving
        saveButton.label = isSaving ? "Saving…" : "Save"
    }

    private func followTiming() {
        guard let timing, !labels.isEmpty else { return }
        // The song moving on changes what can be done.
        if timingShowedPlaying != showsPlayingSong {
            timingShowedPlaying = showsPlayingSong
            refreshTiming()
        }
        let found = showsPlayingSong ? LyricsTiming.current(at: Int(env.player.elapsed * 1000), in: timing.lines) : nil
        guard found != active else { return }
        active = found
        for (index, pair) in labels.enumerated() {
            pair.line.setCSS("current", index == found)
            pair.line.setCSS("past", found.map { index < $0 } ?? false)
        }
        // With a line marked, the view stays on it; with none, it follows the music.
        guard let found, timing.next == nil, holdUntil.map({ $0 < .now }) ?? true else { return }
        scroll(to: found)
    }

    private func save() {
        guard let timing, let lyrics, let id = timingSongID, !isSaving else { return }
        isSaving = true
        refreshTiming()
        let reference = WeakReference(self)
        Task { @MainActor in
            do {
                let saved = try await env.app.saveLyrics(timing, from: lyrics, songID: id)
                guard let pane = reference.value else { return }
                pane.isSaving = false
                pane.endTiming(saved: saved)
            } catch {
                guard let pane = reference.value else { return }
                pane.isSaving = false
                pane.timingError.text = error.localizedDescription
                pane.timingError.isVisible = true
                pane.refreshTiming()
            }
        }
    }

    /// Back to reading: the lyrics as saved, or the song playing now when it moved on.
    private func endTiming(saved: StructuredLyrics?) {
        let id = timingSongID
        timing = nil
        timingSongID = nil
        timingBar.isVisible = false
        menu?.isVisible = true
        lines.removeAll()
        labels = []
        active = nil
        let current = env.player.currentSong?.id
        songID = current
        let reference = WeakReference(self)
        Task { @MainActor in
            guard let pane = reference.value else { return }
            await pane.load(stack: pane.stack, showing: id == current ? saved ?? pane.lyrics : nil)
        }
    }

    /// `0:12.34`.
    private static func stamp(_ milliseconds: Int) -> String {
        let hundredths = milliseconds / 10
        return String(format: "%d:%02d.%02d", hundredths / 6000, hundredths / 100 % 60, hundredths % 100)
    }

    private static func shiftText(_ milliseconds: Int) -> String {
        guard milliseconds != 0 else { return "All lines" }
        let seconds = String(format: "%.1f", Double(abs(milliseconds)) / 1000)
        return milliseconds > 0 ? "\(seconds) s later" : "\(seconds) s sooner"
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
