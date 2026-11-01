import AppKit
import SwiftUI

/// The popover, laid out like the system's own menu bar extras (Weather,
/// Battery): a large state headline, hairline-separated sections and
/// full-width rows that highlight on hover.
struct MenuView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            if model.helperRunning && (!model.onPower || model.remaining != nil) {
                SectionDivider()
                timerSection
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            if model.helperRunning {
                SectionDivider()
                InfoRow(symbol: "light.beacon.max",
                        title: "LED de MagSafe",
                        value: model.status?.blinking == true ? "Parpadeando" : "Normal")
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
            }

            SectionDivider()
            VStack(spacing: 0) {
                MenuRow(title: "Abrir al iniciar sesión", checked: model.launchAtLogin) {
                    model.setLaunchAtLogin(!model.launchAtLogin)
                }
                MenuRow(title: "Salir de MagGlow") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
        }
        .frame(width: 290)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MagGlow")
                    .font(.system(size: 13, weight: .semibold))
                Text(headline)
                    .font(.system(size: 30, weight: .regular))
                    .monospacedDigit()
                    .padding(.top, 2)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .symbolRenderingMode(.hierarchical)
                    .frame(height: 20)
                Text(detail)
                    .font(.system(size: 12, weight: .medium))
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
    }

    private var headline: String {
        if !model.helperRunning { return "Inactivo" }
        if let remaining = model.remaining { return format(remaining) }
        return model.onPower ? "Enchufado" : "Batería"
    }

    private var detail: String {
        if !model.helperRunning { return "Falta el ayudante.\nVuelve a instalar MagGlow" }
        if model.onPower { return "No se suspende,\nni con la tapa cerrada" }
        if model.remaining != nil { return "Despierto con\nla tapa cerrada" }
        return "Se suspende al\ncerrar la tapa"
    }

    private var symbol: String {
        if !model.helperRunning { return "exclamationmark.triangle" }
        if model.remaining != nil { return "timer" }
        return model.onPower ? "bolt.fill" : "battery.75percent"
    }

    // MARK: Timer

    private var timerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("No suspender con la tapa cerrada")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.remaining != nil {
                    Button("Cancelar") { model.cancel() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                }
            }
            HStack(spacing: 8) {
                ForEach([15, 30, 60], id: \.self) { minutes in
                    DurationButton(title: minutes == 60 ? "1 h" : "\(minutes) min") {
                        model.keepAwake(minutes: minutes)
                    }
                }
            }
        }
    }

    private func format(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Building blocks

private struct SectionDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 16)
    }
}

/// A full-width row that highlights on hover, like a menu item.
private struct MenuRow: View {
    let title: String
    var checked: Bool? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if checked == true {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.1) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct InfoRow: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 24)
    }
}

/// Capsule button in the style of Control Center's option chips.
private struct DurationButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(
                    Capsule().fill(Color.primary.opacity(hovering ? 0.16 : 0.08))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
                    Text("\(Int((remaining / 60).rounded(.up))) min")
                }
            } else {
                Image(nsImage: MenuBarIcon.image(led: model.onPower ? .on : .off))
            }
        }
        .menuBarExtraStyle(.window)
    }
}
