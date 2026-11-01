// MagGlow helper: a launchd daemon that runs as root.
//
// - On power, or while the app's battery timer is running, it blocks system
//   sleep (lid closed included) with `pmset disablesleep 1`.
// - While the Mac is awake with the lid closed or the displays asleep, it
//   blinks the MagSafe LED by toggling the SMC key ACLC (3 green, 1 off).
// - Whenever it stops, it hands the LED back to macOS (ACLC 0) and lets the
//   Mac sleep again, so a crash or uninstall never leaves sleep disabled.

import CSMC
import MagGlowShared
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

// IOKit's iokit_common_msg() macros aren't imported into Swift.
let kIOMessageCanSystemSleep: UInt32 = 0xE000_0270
let kIOMessageSystemWillSleep: UInt32 = 0xE000_0280

enum LED: UInt8 {
    case system = 0, off = 1, green = 3
}

final class Helper {
    private var lastLED: LED?
    private var sleepBlocked: Bool?
    private var blinkOn = false
    private var lastStatus: MagGlowStatus?
    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var notifyPort: IONotificationPortRef?

    func start() {
        if smc_open() != 0 {
            log("couldn't open AppleSMC; the LED won't blink")
        }
        try? FileManager.default.createDirectory(at: MagGlowPaths.dir, withIntermediateDirectories: true)
        watchSystemSleep()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer

        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in self?.shutdown() }
            source.resume()
            signalSources.append(source)
        }
    }

    private var timer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []

    private func tick() {
        let request = readRequest()
        let onPower = isOnPower()
        let lidClosed = isLidClosed()
        let timerActive = (request.awakeUntil ?? .distantPast) > Date()
        let wantBlock = onPower || timerActive

        if wantBlock != sleepBlocked {
            setSleepDisabled(wantBlock)
            // Unplugged or timer over with the lid already shut: macOS won't
            // re-check the lid by itself, so ask it to sleep now.
            if !wantBlock && sleepBlocked != nil && lidClosed {
                pmset(["sleepnow"])
            }
            sleepBlocked = wantBlock
        }

        let blink = lidClosed || request.displayAsleep
        if blink {
            blinkOn.toggle()
            setLED(blinkOn ? .green : .off)
        } else {
            blinkOn = false
            setLED(.system)
        }

        writeStatus(MagGlowStatus(onPower: onPower, sleepBlocked: wantBlock, blinking: blink, updated: Date()))
    }

    private func shutdown() {
        setLED(.system, force: true)
        setSleepDisabled(false)
        try? FileManager.default.removeItem(at: MagGlowPaths.status)
        smc_close()
        exit(0)
    }

    // MARK: LED

    private func setLED(_ led: LED, force: Bool = false) {
        guard force || led != lastLED else { return }
        let rc = smc_write_u8("ACLC", led.rawValue)
        if rc == 0 {
            lastLED = led
        } else if lastLED != nil || force {
            log("failed to write ACLC=\(led.rawValue) (\(rc))")
            lastLED = nil
        }
    }

    // MARK: Sleep

    private func setSleepDisabled(_ disabled: Bool) {
        pmset(["disablesleep", disabled ? "1" : "0"])
    }

    private func pmset(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = args
        let errors = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errors
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                log("pmset \(args.joined(separator: " ")) exited with \(p.terminationStatus): \(message)")
            }
        } catch {
            log("pmset \(args.joined(separator: " ")) failed: \(error)")
        }
    }

    /// Hands the LED back to macOS right before the system sleeps, so it
    /// doesn't stay frozen green or dark while the Mac is asleep.
    private func watchSystemSleep() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(context, &notifyPort, { context, _, message, argument in
            guard let context else { return }
            let helper = Unmanaged<Helper>.fromOpaque(context).takeUnretainedValue()
            switch message {
            case kIOMessageSystemWillSleep:
                helper.setLED(.system, force: true)
                IOAllowPowerChange(helper.rootPort, Int(bitPattern: argument))
            case kIOMessageCanSystemSleep:
                IOAllowPowerChange(helper.rootPort, Int(bitPattern: argument))
            default:
                break
            }
        }, &notifier)
        if let notifyPort {
            CFRunLoopAddSource(CFRunLoopGetMain(),
                               IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(),
                               .defaultMode)
        }
    }

    // MARK: State

    private func isOnPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return false }
        return type == kIOPMACPowerKey
    }

    private func isLidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    private func readRequest() -> MagGlowRequest {
        guard let data = try? Data(contentsOf: MagGlowPaths.request),
              let request = try? JSONDecoder.magglow.decode(MagGlowRequest.self, from: data)
        else { return MagGlowRequest() }
        return request
    }

    private func writeStatus(_ status: MagGlowStatus) {
        // Rewrite on change, and every few seconds so the app can tell the
        // helper is alive.
        if let last = lastStatus,
           last.onPower == status.onPower, last.sleepBlocked == status.sleepBlocked,
           last.blinking == status.blinking,
           status.updated.timeIntervalSince(last.updated) < 5 {
            return
        }
        guard let data = try? JSONEncoder.magglow.encode(status) else { return }
        do {
            try data.write(to: MagGlowPaths.status, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: MagGlowPaths.status.path)
            lastStatus = status
        } catch {
            log("couldn't write status.json: \(error)")
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[magglow] \(message)\n".utf8))
    }
}

if CommandLine.arguments.contains("--reset") {
    // Used by the uninstaller.
    _ = smc_open()
    _ = smc_write_u8("ACLC", LED.system.rawValue)
    smc_close()
    exit(0)
}

let helper = Helper()
helper.start()
RunLoop.main.run()
