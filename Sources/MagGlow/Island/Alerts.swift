import AppKit
import IOBluetooth
import SwiftUI

/// Short notices on the closed island: a Focus turning on or off, and a
/// Bluetooth device connecting, with its battery.
@MainActor
final class IslandAlerts: NSObject, ObservableObject {
    enum Alert: Equatable {
        case focus(on: Bool)
        case device(name: String, symbol: String, battery: Int?)
    }

    @Published private(set) var alert: Alert?

    private var hide: DispatchWorkItem?
    private var focusOn: Bool?
    private var focusTimer: Timer?
    private var connectNotification: IOBluetoothUserNotification?

    private static let focusFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")

    override init() {
        super.init()
        focusOn = Self.readFocus()
        watchFocus()
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                         selector: #selector(deviceConnected(_:device:)))
    }

    private func show(_ alert: Alert, for seconds: TimeInterval = 2.6) {
        self.alert = alert
        hide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.alert = nil }
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: Focus

    /// macOS keeps the active Focus in a JSON file; there is no public API
    /// for it. A Focus is on while the file holds an assertion record.
    /// Reading it needs Full Disk Access, which MagGlow doesn't ask for, so
    /// this is only used if it happens to be granted.
    private static func readFocus() -> Bool? {
        guard let data = try? Data(contentsOf: focusFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]]
        else { return nil }
        return entries.contains { ($0["storeAssertionRecords"] as? [Any])?.isEmpty == false }
    }

    /// Without access to its contents, the file's size still tells: turning
    /// a Focus on adds an assertion record of a few hundred bytes, turning
    /// it off removes it. Other rewrites change the size by a few bytes.
    private static let recordBytes = 150

    /// Checks once a second whether the file changed; reading its date and
    /// size needs no permission.
    private func watchFocus() {
        var last = Self.focusAttributes()
        focusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Self.focusAttributes()
                guard let current = now, current.modified != last?.modified else { return }
                defer { last = now }
                if let on = Self.readFocus() {
                    self.focusChanged(on)
                } else if let previous = last {
                    let delta = current.size - previous.size
                    if delta > Self.recordBytes { self.focusChanged(true) }
                    if delta < -Self.recordBytes { self.focusChanged(false) }
                }
            }
        }
    }

    private static func focusAttributes() -> (modified: Date, size: Int)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: focusFile.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.intValue
        else { return nil }
        return (modified, size)
    }

    private func focusChanged(_ on: Bool) {
        guard on != focusOn else { return }
        focusOn = on
        show(.focus(on: on))
    }

    // MARK: Bluetooth

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let name = device.name ?? String(localized: "Device")
        let symbol = Self.symbol(for: device)
        // The battery level arrives a moment after the connection.
        show(.device(name: name, symbol: symbol, battery: Self.battery(of: device)), for: 3)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, case .device(let shown, _, nil)? = self.alert, shown == name,
                      let level = Self.battery(of: device) else { return }
                self.alert = .device(name: name, symbol: symbol, battery: level)
            }
        }
    }

    /// Apple's headphones report each bud; others a single level. These are
    /// private properties, so they are read only if present.
    private static func battery(of device: IOBluetoothDevice) -> Int? {
        func value(_ key: String) -> Int {
            guard device.responds(to: NSSelectorFromString(key)) else { return 0 }
            return (device.value(forKey: key) as? NSNumber)?.intValue ?? 0
        }
        let buds = [value("batteryPercentLeft"), value("batteryPercentRight")].filter { $0 > 0 }
        if let lowest = buds.min() { return lowest }
        for key in ["batteryPercentSingle", "batteryPercentCombined"] where value(key) > 0 { return value(key) }
        return nil
    }

    private static func symbol(for device: IOBluetoothDevice) -> String {
        let name = (device.name ?? "").lowercased()
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("beats") { return "beats.headphones" }
        if name.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
        if name.contains("mouse") || name.contains("ratón") { return "magicmouse.fill" }
        if name.contains("keyboard") || name.contains("teclado") { return "keyboard.fill" }
        switch device.deviceClassMajor {
        case 4: return "headphones" // audio
        case 5: // peripheral: the minor class says keyboard and/or pointer
            if device.deviceClassMinor & 0x10 != 0 { return "keyboard.fill" }
            if device.deviceClassMinor & 0x20 != 0 { return "computermouse.fill" }
            return "gamecontroller.fill"
        case 2: return "iphone"
        default: return "dot.radiowaves.left.and.right"
        }
    }
}

// MARK: - Views

/// An alert on the closed island's wings.
struct AlertView: View {
    let alert: IslandAlerts.Alert
    let wings: IslandModel.Wings
    let notch: CGFloat

    static func wings(for alert: IslandAlerts.Alert) -> IslandModel.Wings {
        switch alert {
        case .focus: return IslandModel.Wings(left: 92, right: 92) // room for "Desactivado"
        case .device: return IslandModel.Wings(left: 36, right: 36)
        }
    }

    var body: some View {
        switch alert {
        case .focus(let on):
            wings {
                Image(systemName: on ? "moon.fill" : "moon")
                    .font(.system(size: 15, weight: .semibold))
            } right: {
                Text(on ? String(localized: "On") : String(localized: "Off"))
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(on ? Color(red: 0.42, green: 0.42, blue: 1) : .white.opacity(0.5))
        case .device(_, let symbol, let battery):
            wings {
                SpinningSymbol(symbol: symbol)
            } right: {
                if let battery { BatteryRing(level: battery) }
            }
        }
    }

    private func wings<L: View, R: View>(@ViewBuilder left: () -> L, @ViewBuilder right: () -> R) -> some View {
        WingsLayout(wings: wings, notch: notch, left: left, right: right)
    }
}

/// The device's symbol, turning in from the side as if in 3D, lit from above.
private struct SpinningSymbol: View {
    let symbol: String
    @State private var angle: Double = -110

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(LinearGradient(colors: [.white, Color(white: 0.72)], startPoint: .top, endPoint: .bottom))
            .shadow(color: .white.opacity(0.25), radius: 3)
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .onAppear {
                withAnimation(.spring(response: 0.9, dampingFraction: 0.62).delay(0.1)) { angle = 0 }
            }
    }
}

/// The battery as a ring: green, yellow when low, red when nearly empty.
private struct BatteryRing: View {
    let level: Int
    @State private var shown: Double = 0

    var body: some View {
        let color: Color = level <= 15 ? Color(red: 1, green: 0.3, blue: 0.3)
            : level <= 35 ? Color(red: 1, green: 0.8, blue: 0.25)
            : Color(red: 0.35, green: 0.85, blue: 0.45)
        ZStack {
            Circle().stroke(color.opacity(0.22), lineWidth: 3)
            Circle()
                .trim(from: 0, to: shown)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.6), radius: 3)
        }
        .frame(width: 17, height: 17)
        .help("\(level) %")
        .onAppear {
            withAnimation(.easeOut(duration: 0.8).delay(0.15)) { shown = Double(level) / 100 }
        }
    }
}
