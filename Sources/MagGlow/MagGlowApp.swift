import AppKit
import ApplicationServices
import IOKit
import MagGlowShared
import ServiceManagement
import SwiftUI

@MainActor
final class Model: ObservableObject {
    @Published private(set) var status: MagGlowStatus?
    @Published private(set) var awakeUntil: Date?
    /// The duration picked from the menu, to tick it while the timer runs.
    @Published private(set) var chosenMinutes: Int?
    @Published private(set) var now = Date()
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Look active to other apps (Teams, Slack…) while MagGlow is open.
    @Published var simulateActivity = UserDefaults.standard.object(forKey: "simulateActivity") as? Bool ?? true {
        didSet { UserDefaults.standard.set(simulateActivity, forKey: "simulateActivity") }
    }
    /// macOS only lets apps with Accessibility access post input events.
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    /// The island over the notch, with today's calendar.
    @Published var islandEnabled = UserDefaults.standard.object(forKey: "islandEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(islandEnabled, forKey: "islandEnabled")
            island.enabled = islandEnabled
        }
    }
    /// The island takes the volume and brightness keys and shows its own
    /// indicator instead of the system's (needs Accessibility access).
    @Published var replaceSystemHUD = UserDefaults.standard.object(forKey: "replaceSystemHUD") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(replaceSystemHUD, forKey: "replaceSystemHUD")
            island.controls.replaceSystemHUD = replaceSystemHUD
        }
    }
    private(set) lazy var island = IslandController(enabled: islandEnabled, replaceSystemHUD: replaceSystemHUD)

    private var displayAsleep = false
    private var ticker: Timer?

    init() {
        if let data = try? Data(contentsOf: MagGlowPaths.request),
           let saved = try? JSONDecoder.magglow.decode(MagGlowRequest.self, from: data),
           let until = saved.awakeUntil, until > Date() {
            awakeUntil = until
        }
        writeRequest()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setDisplayAsleep(true) }
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setDisplayAsleep(false) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeRequest() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.awakeUntil = nil
                self?.displayAsleep = false
                self?.writeRequest()
            }
        }

        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
        // Once the app has finished launching, so the window can be shown.
        DispatchQueue.main.async { [weak self] in _ = self?.island }
    }

    var helperRunning: Bool {
        guard let status else { return false }
        return now.timeIntervalSince(status.updated) < 15
    }

    var onPower: Bool { status?.onPower ?? false }

    var remaining: TimeInterval? {
        guard let awakeUntil else { return nil }
        let left = awakeUntil.timeIntervalSince(now)
        return left > 0 ? left : nil
    }

    func keepAwake(minutes: Int) {
        awakeUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        chosenMinutes = minutes
        writeRequest()
        tick()
    }

    func cancel() {
        awakeUntil = nil
        chosenMinutes = nil
        writeRequest()
        tick()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("MagGlow: launch at login: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func requestAccessibility() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if !AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// After this long without input, nudge the system so it counts as used.
    /// Well under the 5 minutes after which chat apps mark you away.
    private static let activityInterval: TimeInterval = 60

    /// Posts a mouse move to where the pointer already is: nothing visible
    /// happens, but the system's idle time (what apps check to mark you
    /// away) starts over. Skipped while the displays are off, or with the lid
    /// closed and no external display, since input would turn them back on.
    private func simulateActivityIfIdle() {
        accessibilityGranted = AXIsProcessTrusted()
        guard simulateActivity, accessibilityGranted, !displayAsleep else { return }
        if Self.isLidClosed() && !Self.hasExternalDisplay() { return }
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
        guard idle >= Self.activityInterval,
              let location = CGEvent(source: nil)?.location,
              let move = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .mouseMoved,
                                 mouseCursorPosition: location, mouseButton: .left)
        else { return }
        move.post(tap: .cghidEventTap)
    }

    private static func isLidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    private func setDisplayAsleep(_ asleep: Bool) {
        displayAsleep = asleep
        writeRequest()
    }

    private func tick() {
        now = Date()
        if let awakeUntil, awakeUntil <= now {
            self.awakeUntil = nil
            chosenMinutes = nil
            writeRequest()
        }
        if let data = try? Data(contentsOf: MagGlowPaths.status) {
            status = try? JSONDecoder.magglow.decode(MagGlowStatus.self, from: data)
        } else {
            status = nil
        }
        simulateActivityIfIdle()
    }

    private static func hasExternalDisplay() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    private func writeRequest() {
        let request = MagGlowRequest(awakeUntil: awakeUntil, displayAsleep: displayAsleep,
                                     externalDisplay: Self.hasExternalDisplay())
        guard let data = try? JSONEncoder.magglow.encode(request) else { return }
        do {
            try data.write(to: MagGlowPaths.request, options: .atomic)
        } catch {
            NSLog("MagGlow: couldn't write request: \(error)")
        }
    }
}

