import AppKit
import MagGlowShared
import ServiceManagement
import SwiftUI

@MainActor
final class Model: ObservableObject {
    @Published private(set) var status: MagGlowStatus?
    @Published private(set) var awakeUntil: Date?
    @Published private(set) var now = Date()
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

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
        writeRequest()
        tick()
    }

    func cancel() {
        awakeUntil = nil
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

    private func setDisplayAsleep(_ asleep: Bool) {
        displayAsleep = asleep
        writeRequest()
    }

    private func tick() {
        now = Date()
        if let awakeUntil, awakeUntil <= now {
            self.awakeUntil = nil
            writeRequest()
        }
        if let data = try? Data(contentsOf: MagGlowPaths.status) {
            status = try? JSONDecoder.magglow.decode(MagGlowStatus.self, from: data)
        } else {
            status = nil
        }
    }

    private func writeRequest() {
        let request = MagGlowRequest(awakeUntil: awakeUntil, displayAsleep: displayAsleep)
        guard let data = try? JSONEncoder.magglow.encode(request) else { return }
        do {
            try data.write(to: MagGlowPaths.request, options: .atomic)
        } catch {
            NSLog("MagGlow: couldn't write request: \(error)")
        }
    }
}

