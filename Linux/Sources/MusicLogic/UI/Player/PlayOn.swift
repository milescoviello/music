import CGtk
import Foundation

/// Play On, the phone's: this computer, and every other one on the network running Music
/// with Remote Control on, to play to. Choosing one pairs first if need be (that computer
/// shows a code), then the player here plays and shows what plays there.
@MainActor
enum PlayOn {
    /// Made with the app's state, in `MusicApplication`.
    static var players: RemotePlayers?

    /// The player's button, tinted while another computer is being played to.
    static func button(_ env: Env) -> Widget {
        let button = Button(icon: "video-display-symbolic", "flat", "np-small")
        button.tooltip("Play On")
        button.onClicked { present(env) }
        button.observe {
            let session = players?.session
            button.setCSS("active", session != nil)
            button.tooltip(session.map { "Playing on \($0.computer.name)" } ?? "Play On")
        }
        return button
    }

    /// "Playing on …" and the way back, over the player while another computer plays.
    static func banner(_ env: Env) -> Widget {
        let label = Label("", "caption").ellipsize()
        let back = Button("Play Here", "flat", "pill") { chooseHere(env) }
        let banner = Box.horizontal(spacing: 8) {
            Icon("video-display-symbolic", size: 14)
            label.hexpand().xalign(0)
            back
        }
        banner.css("play-on-banner").margin(horizontal: 12, vertical: 4)
        banner.observe {
            guard let session = players?.session else {
                banner.isVisible = false
                return
            }
            banner.isVisible = true
            let name = session.computer.name
            switch session.status {
            case .connecting: label.text = "Connecting to \(name)…"
            case .connected: label.text = players?.playsFromAnotherServer == true ? "\(name) is signed in to a different server" : "Playing on \(name)"
            case .reconnecting: label.text = "Reconnecting to \(name)…"
            case .unreachable: label.text = "Can't reach \(name)"
            }
        }
        return banner
    }

    // MARK: - The picker

    static func present(_ env: Env) {
        guard let players else { return }
        let rows = ListBox()
        let problem = Label("", "caption", "warning").wrap().visible(false)
        let add = Button("Add by Address…", "flat") {
            Dialogs.prompt(
                "Add a Computer",
                body: "Its address is in Settings → Remote Control on that computer.",
                placeholder: "192.168.1.20", confirm: "Add"
            ) { address in Task { await players.add(address: address) } }
        }.halign(GTK_ALIGN_START)
        let body = Box.vertical(spacing: 12) {
            rows
            Label("Computers on this network with Music open and Remote Control on appear here. The first time, the computer shows a code to type in.", "caption", "dim").wrap().xalign(0)
            problem
            add
        }.margin(horizontal: 18, vertical: 18)
        let dialog = Dialogs.sheet("Play On", content: ScrolledWindow(body).vexpand(), width: 440, height: 520)

        players.startBrowsing()
        Signal.connect(dialog, "closed") { players.stopBrowsing() }

        var asking = false
        body.observe {
            let computers = players.computers
            let nearby = players.nearby
            let session = players.session
            rows.removeAll()
            rows.append(row("computer-symbolic", "This Computer", nil, isCurrent: session == nil)) { chooseHere(env) }
            for computer in computers {
                let isCurrent = session?.computer.id == computer.id
                let line = row("video-display-symbolic", computer.name, detail(computer, nearby: nearby.contains(computer.id), isCurrent: isCurrent), isCurrent: isCurrent)
                if computer.isPaired {
                    line.contextMenu {
                        Menu([[.action("Forget \(computer.name)", destructive: true) { Task { await players.forget(computer) } }]])
                    }
                }
                rows.append(line) {
                    guard !isCurrent else { return }
                    choose(env, computer)
                }
            }
            problem.text = players.problem ?? ""
            problem.isVisible = players.problem != nil
            // The computer is showing a code: ask for it.
            if let pairing = players.pairing, !asking {
                asking = true
                Dialogs.prompt(
                    "Enter the Code",
                    body: "Type the code \(pairing.name) is showing.",
                    placeholder: "123 456", confirm: "Pair"
                ) { code in
                    asking = false
                    Task { await players.finishPairing(code: code.filter(\.isNumber)) }
                }
            }
        }
    }

    private static func row(_ icon: String, _ title: String, _ detail: String?, isCurrent: Bool) -> Widget {
        let check = Icon("object-select-symbolic", size: 16).css("accent")
        check.isVisible = isCurrent
        return Box.horizontal(spacing: 12) {
            Icon(icon, size: 20)
            Box.vertical(spacing: 2) {
                Label(title).xalign(0).ellipsize()
                if let detail { Label(detail, "caption", "dim").xalign(0).ellipsize() }
            }.hexpand()
            check
        }.margin(horizontal: 12, vertical: 10)
    }

    private static func detail(_ computer: RemotePlayers.Computer, nearby: Bool, isCurrent: Bool) -> String? {
        if isCurrent, let session = players?.session {
            switch session.status {
            case .connecting: return "Connecting…"
            case .connected: return "Playing here now"
            case .reconnecting: return "Reconnecting…"
            case .unreachable: return "Can't be reached"
            }
        }
        if !computer.isPaired { return "Not paired: choose it to pair" }
        return nearby || computer.host != nil ? "Paired" : "Paired, not seen on this network"
    }

    /// With music playing here, the phone's question: move it there, or just control it.
    private static func choose(_ env: Env, _ computer: RemotePlayers.Computer) {
        guard let players else { return }
        guard computer.isPaired, players.session == nil, env.player.hasQueue else {
            Task { await players.select(computer) }
            return
        }
        Dialogs.alert(
            "Play on \(computer.name)",
            responses: [
                ("cancel", "Cancel", ADW_RESPONSE_DEFAULT),
                ("control", "Just Control It", ADW_RESPONSE_DEFAULT),
                ("move", "Move What's Playing", ADW_RESPONSE_SUGGESTED),
            ],
            defaultResponse: "move"
        ) { response in
            guard response != "cancel" else { return }
            Task { await players.select(computer, moving: response == "move") }
        }
    }

    /// Back to this computer: bring what plays there, or leave it playing.
    static func chooseHere(_ env: Env) {
        guard let players, let session = players.session else { return }
        guard !session.mirror.queue.isEmpty else {
            Task { await players.playHere(moving: false) }
            return
        }
        Dialogs.alert(
            "Play on This Computer",
            responses: [
                ("cancel", "Cancel", ADW_RESPONSE_DEFAULT),
                ("leave", "Leave It Playing There", ADW_RESPONSE_DEFAULT),
                ("move", "Move What's Playing Here", ADW_RESPONSE_SUGGESTED),
            ],
            defaultResponse: "move"
        ) { response in
            guard response != "cancel" else { return }
            Task { await players.playHere(moving: response == "move") }
        }
    }
}
