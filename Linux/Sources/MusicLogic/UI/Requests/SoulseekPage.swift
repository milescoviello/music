import CGtk
import Foundation

// slskd on the server, watched, as on the phone (`SoulseekMonitorView`): whether it is
// signed in to Soulseek, what it shares and sends, its downloads by folder -- under way
// first, then the last week's -- and the imports that take a finished download into the
// library. Read every few seconds while the page is open (`GrabService.beginMonitoring`).

@MainActor
enum SoulseekPage {
    static func make(_ env: Env) -> NavigationPage {
        let grab = env.app.grab
        let body = Box.vertical(spacing: 18)
        // The page is rebuilt as it updates: an opened folder stays open, and the page stays
        // where it was scrolled to.
        var expanded: Set<String> = []
        var scroller: ScrolledWindow?

        body.observe {
            let offset = scroller.map { gtk_adjustment_get_value($0.verticalAdjustment) }
            defer {
                if let scroller, let offset { gtk_adjustment_set_value(scroller.verticalAdjustment, offset) }
            }
            body.removeAll()
            guard let monitor = grab.monitor else {
                if grab.monitorFailed {
                    body.append(StatusPage(icon: "network-offline-symbolic", title: "Can’t Reach the Server",
                                           description: "The request service on the server isn't answering, so there's nothing to show about Soulseek."))
                } else {
                    body.append(Spinner().size(32).halign(GTK_ALIGN_CENTER).margin(48))
                }
                return
            }
            body.append(status(monitor, stale: grab.monitorFailed))
            body.append(downloads(env, monitor, expanded: expanded) { id, open in
                if open { expanded.insert(id) } else { expanded.remove(id) }
            })
            body.append(imports(env, monitor))
        }
        body.onMap { grab.beginMonitoring() }
        body.onUnmap { grab.endMonitoring() }
        let page = Page.make("Soulseek", content: body.margin(horizontal: 12, vertical: 6))
        scroller = page.scroller
        // Scrolled only by the person, as the player is: following focus, each rebuild took
        // the page back up to the folder last clicked.
        if let window = page.scroller, let viewport = gtk_scrolled_window_get_child(window.widget.cast()) {
            gtk_viewport_set_scroll_to_focus(OpaquePointer(viewport), 0)
        }
        return page
    }

    // MARK: - slskd itself

    private static func status(_ monitor: SonicClient.SlskdMonitor, stale: Bool) -> Widget {
        let status = monitor.slskd
        let lines = [status.connectionLine, stale ? "The last look didn't get an answer; this is from before." : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }
        let head = ActionRow(status.headline, subtitle: lines.joined(separator: "\n"))
            .subtitleLines(3)
            .prefix(statusIcon(status, failed: false))
        let group = PreferencesGroup("Soulseek") { head }
        if let sharing = status.sharingLine { group.add(value("Sharing", sharing)) }
        if let uploads = status.uploadsLine { group.add(value("Uploads", uploads)) }
        group.add(value("Getting Music", monitor.running == 0
            ? "No job running"
            : monitor.running == 1 ? "1 job following its downloads" : "\(monitor.running) jobs following their downloads"))
        if let version = status.version {
            group.add(value("slskd", version + (status.updateAvailable == true ? " · update available" : "")))
        }
        return group
    }

    private static func value(_ title: String, _ text: String) -> Widget {
        ActionRow(title).suffix(Label(text, "dim").valign(GTK_ALIGN_CENTER))
    }

    /// Green when signed in, orange when slskd is up but not signed in, red when it or the
    /// server doesn't answer; a spinner before the first answer.
    static func statusIcon(_ status: SonicClient.SlskdStatus?, failed: Bool) -> Widget {
        guard let status else {
            return failed ? Icon("dialog-error-symbolic").css("error") : Spinner().size(20)
        }
        if status.isOnline { return Icon("object-select-symbolic").css("success") }
        return status.reachable ? Icon("dialog-warning-symbolic").css("warning") : Icon("dialog-error-symbolic").css("error")
    }

    // MARK: - Downloads

    private static func downloads(_ env: Env, _ monitor: SonicClient.SlskdMonitor, expanded: Set<String>,
                                  toggled: @escaping @MainActor (String, Bool) -> Void) -> Widget {
        let group = PreferencesGroup("Downloads", description: "Under way first, then the last week's, newest first.")
        if monitor.downloads.folders.isEmpty {
            group.add(ActionRow("Nothing downloaded this week."))
        }
        for folder in monitor.downloads.folders {
            let row = ExpanderRow(folder.folder, subtitle: "\(folder.detailLine())\n\(folder.sourceLine)")
                .subtitleLines(3)
                .prefix(folderIcon(folder.state))
            if folder.state == .downloading {
                let bar = ProgressBar()
                bar.fraction = folder.fraction
                row.suffix(bar.size(width: 120, height: -1).valign(GTK_ALIGN_CENTER))
            }
            for file in folder.items {
                let line = ActionRow(file.name, subtitle: file.stateLine).subtitleLines(2)
                if file.didFail { line.css("error") }
                row.add(line)
            }
            if let id = requestID(folder.job) {
                row.add(ActionRow("Open the Request") { env.open(.grabRequest(id)) }.chevron())
            }
            row.isExpanded = expanded.contains(folder.id)
            row.onExpandedChange { toggled(folder.id, $0) }
            group.add(row)
        }
        return group
    }

    private static func folderIcon(_ state: SonicClient.SlskdFolder.State) -> Widget {
        switch state {
        case .downloading: Icon("folder-download-symbolic").css("accent")
        case .queued: Icon("document-open-recent-symbolic").css("dim-label")
        case .done: Icon("object-select-symbolic").css("success")
        case .partial: Icon("dialog-warning-symbolic").css("warning")
        case .failed: Icon("dialog-error-symbolic").css("error")
        }
    }

    // MARK: - Imports

    private static func imports(_ env: Env, _ monitor: SonicClient.SlskdMonitor) -> Widget {
        let group = PreferencesGroup(
            "Imports",
            description: "A finished download is checked for fake or broken files, copied into the library, and listed once Navidrome has it."
        )
        if monitor.imports.isEmpty {
            group.add(ActionRow("Nothing imported this week."))
        }
        for item in monitor.imports {
            let lines = [item.subtitle, item.detailLine(), item.folder].compactMap { $0 }
            let row = ActionRow(item.title ?? "Untitled", subtitle: lines.joined(separator: "\n"))
                .subtitleLines(4)
                .prefix(importIcon(item.state))
            if let id = requestID(item.job) {
                row.chevron()
                row.activated { env.open(.grabRequest(id)) }
            }
            group.add(row)
        }
        return group
    }

    private static func importIcon(_ state: SonicClient.SlskdImport.State) -> Widget {
        switch state {
        case .importing, .indexing: Spinner().size(20)
        case .done: Icon("object-select-symbolic").css("success")
        case .failed: Icon("dialog-error-symbolic").css("error")
        case .held: Icon("media-playback-pause-symbolic").css("warning")
        }
    }

    /// The app's own requests are music-grab jobs named `app-<id>`.
    private static func requestID(_ job: String?) -> String? {
        guard let job, job.hasPrefix("app-") else { return nil }
        return String(job.dropFirst(4))
    }
}
