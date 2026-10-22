import CGtk
import Foundation

/// Settings → Remote Control: whether phones may control this computer, what they see it
/// called, and which ones are paired.
@MainActor
enum RemoteControlPage {
    static func make(_ env: Env) -> NavigationPage {
        let remote = RemoteControlServer.shared
        let page = PreferencesPage()

        let enabled = SwitchRow("Allow Control from Phones", isOn: remote.isEnabled) { remote.isEnabled = $0 }
        let name = EntryRow("Name", text: remote.name).onApply { text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { remote.name = String(trimmed.prefix(60)) }
        }
        let address = ActionRow("Address")
        let addressValue = Label("", "dim").selectable()
        address.suffix(addressValue)
        let connected = ActionRow("Connected Now")
        let connectedValue = Label("", "dim")
        connected.suffix(connectedValue)
        page.add(PreferencesGroup("Remote Control", description: """
        The Music app on your iPhone can play to this computer, the way Plexamp plays to \
        another Plexamp: in its player, tap the computer button and choose this name. The \
        first time, this computer shows a code to type in on the phone. Only phones on this \
        network can reach it.
        """) {
            enabled
            name
            address
            connected
        })
        address.observe {
            name.isSensitive = remote.isEnabled
            guard let port = remote.port else {
                addressValue.text = remote.isEnabled ? "Not listening" : "Off"
                return
            }
            let addresses = HTTPServer.localAddresses()
            addressValue.text = addresses.isEmpty ? "Port \(port)" : addresses.map { "\($0):\(port)" }.joined(separator: ", ")
        }
        connected.observe {
            let count = remote.listenerCount
            connectedValue.text = count == 0 ? "None" : count == 1 ? "1 phone" : "\(count) phones"
        }

        let paired = PreferencesGroup("Paired Phones", description: "A phone forgotten here has to pair again before it can control this computer.")
        let list = ListBox()
        paired.add(list)
        page.add(paired)
        list.observe {
            // A row rather than the list's placeholder, which `removeAll` takes away too.
            list.removeAll()
            if remote.devices.isEmpty {
                list.append(ActionRow("None yet", subtitle: "Pair from the phone: in its player, tap the computer button."))
            }
            for device in remote.devices {
                let row = ActionRow(device.name, subtitle: subtitle(for: device))
                row.suffix(Button("Forget", "flat") {
                    remote.forget(device)
                }.valign(GTK_ALIGN_CENTER))
                list.append(row)
            }
        }

        return SettingsPages.preferencesPage("Remote Control", page)
    }

    private static func subtitle(for device: RemoteControlServer.Device) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let paired = "Paired \(formatter.localizedString(for: device.pairedAt, relativeTo: .now))"
        guard let seen = device.lastSeenAt else { return paired }
        return "\(paired) · last used \(formatter.localizedString(for: seen, relativeTo: .now))"
    }

    /// What the settings list says about it.
    static var summary: String {
        let remote = RemoteControlServer.shared
        guard remote.isEnabled else { return "Off" }
        if remote.listenerCount > 0 { return remote.listenerCount == 1 ? "1 phone connected" : "\(remote.listenerCount) phones connected" }
        let count = remote.devices.count
        return count == 0 ? "On" : count == 1 ? "1 phone paired" : "\(count) phones paired"
    }
}

/// The code a phone asking to pair must type in, shown in the window and as a
/// notification, since the computer may be across the room behind other windows.
@MainActor
enum RemotePairingPrompt {
    private static var dialog: OpaquePointer?
    private static let notificationID = "remote-pairing"

    static func install() {
        RemoteControlServer.shared.onPairing = { show($0) }
    }

    private static func show(_ pairing: RemoteControlServer.Pairing?) {
        if let dialog {
            // Forgotten first, so its response is not taken for a refusal of the next one.
            self.dialog = nil
            adw_dialog_close(dialog.cast())
        }
        if let application = Desktop.application {
            g_application_withdraw_notification(application.cast(), notificationID)
        }
        guard let pairing else { return }

        let code = "\(pairing.code.prefix(3)) \(pairing.code.suffix(3))"
        let created = adw_alert_dialog_new(
            "Pair with \(pairing.device)?",
            "Type this code on \(pairing.device) to let it control the music here."
        )!
        let dialog = OpaquePointer(created)
        adw_alert_dialog_add_response(created.cast(), "cancel", "Don’t Allow")
        adw_alert_dialog_set_close_response(created.cast(), "cancel")
        adw_alert_dialog_set_extra_child(created.cast(), Label(code, "title-1", "numeric").xalign(0.5).widget)
        Signal.connect(created, "response", pointer: { _ in
            // Closed by the person, rather than by the pairing finishing or being replaced.
            guard self.dialog == dialog else { return }
            self.dialog = nil
            RemoteControlServer.shared.cancelPairing()
        })
        self.dialog = dialog
        adw_dialog_present(created.cast(), Desktop.window)

        if let application = Desktop.application {
            let notification = g_notification_new("Pair with \(pairing.device)")!
            g_notification_set_body(notification, "Type \(code) on \(pairing.device) to let it control the music here.")
            g_notification_set_priority(notification, G_NOTIFICATION_PRIORITY_HIGH)
            g_application_send_notification(application.cast(), notificationID, notification)
            g_object_unref(notification.cast())
        }
    }
}
