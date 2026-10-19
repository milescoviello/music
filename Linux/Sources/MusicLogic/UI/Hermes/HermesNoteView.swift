import CGtk
import Foundation

/// A written note about a record or an artist, from Hermes — the phone's
/// `HermesNoteSection`. Written once and cached on disk; a failure is never cached, so it
/// can be asked again.
@MainActor
enum HermesNoteView {
    static func make(_ env: Env, subject: HermesNoteSubject, compact: Bool = false) -> Widget {
        let app = env.app
        let slot = Bin()
        let alive = slot.liveness
        let key = "note-\(subject.kind)-\(subject.id)"

        func showNote(_ note: HermesNote) {
            guard alive.isAlive else { return }
            let paragraphs = note.paragraphs
            guard !paragraphs.isEmpty else { return }
            let box = Box.vertical(spacing: 6) {
                Label(compact ? paragraphs[0] : paragraphs.joined(separator: "\n\n"), "dim").wrap().selectable()
            }
            if !compact, let sources = note.sources, !sources.isEmpty {
                box.append(Label("Sources: \(sources.joined(separator: ", "))", "caption", "dimmer").wrap())
            }
            slot.child = box
        }

        func showAsk(failure: String? = nil) {
            guard alive.isAlive else { return }
            guard app.hermes.isAvailable else {
                slot.child = nil
                return
            }
            let button = Button(
                subject.kind == "album" ? "Ask Hermes about this album" : "Ask Hermes about this artist",
                icon: "starred-symbolic", "pill"
            )
            button.halign(GTK_ALIGN_START)
            let box = Box.vertical(spacing: 4) { button }
            if let failure { box.append(Label(failure, "caption", "warning").wrap()) }
            button.onClicked {
                slot.child = Box.horizontal(spacing: 8) {
                    Spinner().size(16)
                    Label("Hermes is writing…", "caption", "dim")
                }
                Task { @MainActor in
                    let outcome = await app.hermes.ask(
                        route: "music-notes",
                        fields: ["kind": subject.kind, "name": subject.name, "artist": subject.artist ?? ""],
                        as: HermesNote.self,
                        timeout: 150
                    )
                    switch outcome {
                    case let .ok(written):
                        await app.cache.store(written, for: key)
                        showNote(written)
                    case let .failed(message):
                        showAsk(failure: message)
                    case .pending:
                        showAsk(failure: "Hermes is taking longer than usual — try again in a minute.")
                    }
                }
            }
            slot.child = box
        }

        Task { @MainActor in
            if let note = await app.cache.load(HermesNote.self, for: key) {
                showNote(note)
            } else {
                showAsk()
            }
        }
        return slot
    }
}
