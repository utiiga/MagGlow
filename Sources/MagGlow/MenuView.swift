import AppKit
import SwiftUI

/// The menu bar menu. It uses the system's own menu (MenuBarExtra's `.menu`
/// style), so it looks like every other menu bar extra; this view only
/// supplies its items.
struct MenuView: View {
    @ObservedObject var model: Model

    var body: some View {
        // Status rows are buttons, not Text: the menu greys out plain text
        // as if it were a disabled item. They open Battery settings, like
        // the system's battery menu does.
        Section("MagGlow") {
            Button(action: openBatterySettings) { Label(headline, systemImage: symbol) }
            Button(action: openBatterySettings) { Label(detail, systemImage: "laptopcomputer") }
            if model.helperRunning {
                Button(action: openBatterySettings) {
                    Label(model.status?.blinking == true ? "MagSafe LED: blinking" : "MagSafe LED: normal",
                          systemImage: "light.beacon.max")
                }
            }
        }

        if model.helperRunning && (!model.onPower || model.remaining != nil) {
            Divider()
            Section("Stay awake with the lid closed") {
                ForEach([15, 30, 60, 240, 480], id: \.self) { minutes in
                    Toggle(minutes >= 60 ? "\(minutes / 60) h" : "\(minutes) min", isOn: Binding(
                        get: { model.remaining != nil && model.chosenMinutes == minutes },
                        set: { on in on ? model.keepAwake(minutes: minutes) : model.cancel() }
                    ))
                }
                if let remaining = model.remaining {
                    Button("Cancel (\(format(remaining)) left)") { model.cancel() }
                }
            }
        }

        Divider()
        Toggle("Simulate activity", isOn: $model.simulateActivity)
        if (model.simulateActivity || (model.islandEnabled && model.replaceSystemHUD)) && !model.accessibilityGranted {
            Button("Allow in Accessibility settings…") { model.requestAccessibility() }
        }
        FichajeMenu(fichaje: model.island.fichaje)

        Divider()
        Toggle("Island over the notch", isOn: $model.islandEnabled)
        if model.islandEnabled {
            Toggle("Volume and brightness in the island", isOn: $model.replaceSystemHUD)
        }
        Toggle("Open at login", isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        ))
        Button("Quit MagGlow") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var headline: String {
        if !model.helperRunning { return String(localized: "Inactive") }
        if model.remaining != nil { return String(localized: "Awake with the lid closed") }
        return model.onPower ? String(localized: "Plugged in") : String(localized: "Battery")
    }

    private var detail: String {
        if !model.helperRunning { return String(localized: "Helper missing. Reinstall MagGlow") }
        if model.onPower { return String(localized: "Won't sleep, even with the lid closed") }
        if model.remaining != nil { return String(localized: "Won't sleep until the time is up") }
        return String(localized: "Sleeps when the lid closes")
    }

    private var symbol: String {
        if !model.helperRunning { return "exclamationmark.triangle" }
        if model.remaining != nil { return "timer" }
        return model.onPower ? "bolt.fill" : "battery.75percent"
    }

    private func openBatterySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func format(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.up))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

@main
struct MagGlowApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            // Plugged in: LED lit. Battery: LED hollow, plus the minutes left
            // while the lid timer runs. Helper down: a warning.
            if !model.helperRunning {
                Image(systemName: "exclamationmark.triangle")
            } else if let remaining = model.remaining {
                HStack(spacing: 3) {
                    Image(nsImage: MenuBarIcon.image(led: .on))
                    Text(MenuBarIcon.shortTime(remaining))
                }
            } else {
                Image(nsImage: MenuBarIcon.image(led: model.onPower ? .on : .off))
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

/// The workday in the menu: connect with a token, see the day, clock in
/// or out, disconnect.
private struct FichajeMenu: View {
    @ObservedObject var fichaje: Fichaje

    var body: some View {
        Section("Workday") {
            if fichaje.connected {
                if let estado = fichaje.estado {
                    Button(action: fichaje.marcar) {
                        Label("\(estado.titulo) · \(Fichaje.hm(fichaje.minutesWorked(at: Date())))",
                              systemImage: estado.dentro ? "record.circle" : "pause.circle")
                    }
                    Button(estado.boton, action: fichaje.marcar)
                        .disabled(fichaje.busy)
                } else if let error = fichaje.error {
                    Button(action: fichaje.refresh) { Label(error, systemImage: "exclamationmark.triangle") }
                }
                Button("Disconnect workday") { fichaje.disconnect() }
            } else {
                Button("Connect workday…") { connect() }
            }
        }
    }

    /// Asks for the server address and the personal clock-in token.
    private func connect() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "Connect your workday")
        alert.informativeText = String(localized: "Enter your clock-in server's address and your personal clock-in token. The token is kept in your Keychain.")
        let address = NSTextField(frame: NSRect(x: 0, y: 30, width: 300, height: 24))
        address.placeholderString = String(localized: "Server address")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = String(localized: "Token")
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 54))
        stack.addSubview(address)
        stack.addSubview(field)
        alert.accessoryView = stack
        alert.addButton(withTitle: String(localized: "Connect"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = address
        address.nextKeyView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let host = address.stringValue, token = field.stringValue
        Task { @MainActor in
            if await !fichaje.connect(host: host, token: token) {
                let failed = NSAlert()
                failed.messageText = String(localized: "Couldn't connect")
                failed.informativeText = fichaje.error ?? String(localized: "Check the address and the token and try again.")
                NSApp.activate(ignoringOtherApps: true)
                failed.runModal()
            }
        }
    }
}
