import AppKit
import AudioToolbox
import CoreAudio

/// Output volume and display brightness, and the island's own indicator for
/// them in place of the system's.
///
/// With Accessibility access, MagGlow takes the volume and brightness keys
/// itself (an event tap), so macOS doesn't draw its indicator and only the
/// island's shows. Without it, the island still follows volume changes, but
/// the system's indicator appears too.
@MainActor
final class SystemControls: ObservableObject {
    enum Kind { case volume, brightness }

    struct HUD: Equatable {
        var kind: Kind
        var level: Float
        var muted: Bool
    }

    @Published private(set) var hud: HUD?
    @Published private(set) var volume: Float = 0
    @Published private(set) var muted = false
    /// SF Symbol for where the sound goes: the Mac, headphones, a TV…
    @Published private(set) var outputSymbol = "laptopcomputer"
    /// The island is open, so changes show there instead of as an indicator.
    var suppressHUD = false

    var replaceSystemHUD: Bool {
        didSet { updateTap() }
    }

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var hideHUD: DispatchWorkItem?
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var watchedDevice = AudioObjectID(kAudioObjectUnknown)

    private static let step: Float = 1 / 16
    private static let fineStep: Float = 1 / 64

    init(replaceSystemHUD: Bool) {
        self.replaceSystemHUD = replaceSystemHUD
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
        outputChanged()
        updateTap()
    }

    // MARK: Volume

    func setVolume(_ value: Float) {
        let v = min(max(value, 0), 1)
        var scalar = Float32(v)
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar)
        if muted && v > 0 { setMuted(false) }
        volume = v
    }

    func setMuted(_ on: Bool) {
        var flag = UInt32(on ? 1 : 0)
        var address = Self.address(kAudioDevicePropertyMute)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &flag)
        muted = on
    }

    private func readVolume() {
        var scalar = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &scalar) == noErr { volume = scalar }
        var flag = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address = Self.address(kAudioDevicePropertyMute)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &flag) == noErr { muted = flag != 0 }
    }

    private func outputChanged() {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        device = id
        outputSymbol = Self.symbol(for: id)
        readVolume()

        // Follow changes made elsewhere (Control Center, another app…).
        guard id != watchedDevice else { return }
        watchedDevice = id
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(id, &address, .main) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, self.device == id else { return }
                    let before = (self.volume, self.muted)
                    self.readVolume()
                    if before != (self.volume, self.muted) { self.show(.volume) }
                }
            }
        }
    }

    private static func symbol(for device: AudioObjectID) -> String {
        var type = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = address(kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &type)
        switch type {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt: return "hifispeaker"
        default: return "laptopcomputer"
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    // MARK: Brightness

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    /// DisplayServices is private, so it is looked up at run time.
    private static let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getBrightness: GetBrightness? = displayServices.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: GetBrightness.self) }
    private static let setBrightness: SetBrightness? = displayServices.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: SetBrightness.self) }

    private static var builtInDisplay: CGDirectDisplayID {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? CGMainDisplayID()
    }

    private func brightness() -> Float? {
        var value: Float = 0
        guard let get = Self.getBrightness, get(Self.builtInDisplay, &value) == 0 else { return nil }
        return value
    }

    /// Where brightness is heading, and the timer easing it there: stepping
    /// straight to the new value looks jumpy, like the system's own does not.
    private var brightnessTarget: Float?
    private var brightnessTimer: Timer?

    /// False when brightness can't be changed here, so the key goes to macOS.
    private func changeBrightness(by delta: Float) -> Bool {
        guard let current = brightness(), Self.setBrightness != nil else { return false }
        // Keys repeat faster than the fade: build on where it is heading.
        let value = min(max((brightnessTarget ?? current) + delta, 0), 1)
        brightnessTarget = value
        show(.brightness, level: value)
        if brightnessTimer == nil {
            brightnessTimer = Timer.scheduledTimer(withTimeInterval: 1 / 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.stepBrightness() }
            }
        }
        return true
    }

    /// Moves a fraction of the remaining way each frame (about 0.18 s in all).
    private func stepBrightness() {
        guard let target = brightnessTarget, let set = Self.setBrightness, let current = brightness() else {
            brightnessTimer?.invalidate()
            brightnessTimer = nil
            return
        }
        let gap = target - current
        if abs(gap) < 0.002 {
            _ = set(Self.builtInDisplay, target)
            brightnessTimer?.invalidate()
            brightnessTimer = nil
            brightnessTarget = nil
            return
        }
        _ = set(Self.builtInDisplay, current + gap * 0.18)
    }

    // MARK: Keys

    /// NX_KEYTYPE_* codes of the media keys this handles.
    private enum Key: Int {
        case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
    }

    /// Returns true when the key was handled and should not reach macOS.
    fileprivate func handleKey(_ code: Int, down: Bool, fine: Bool) -> Bool {
        guard let key = Key(rawValue: code) else { return false }
        let step = fine ? Self.fineStep : Self.step
        // Brightness keys fall through to macOS when they can't be handled.
        if key == .brightnessUp || key == .brightnessDown {
            guard brightness() != nil else { return false }
            if down { _ = changeBrightness(by: key == .brightnessUp ? step : -step) }
            return true
        }
        guard down else { return true }
        switch key {
        case .soundUp: setVolume(volume + step)
        case .soundDown: setVolume(volume - step)
        case .mute: setMuted(!muted)
        default: break
        }
        show(.volume)
        return true
    }

    private func show(_ kind: Kind, level: Float? = nil) {
        guard !suppressHUD else { return }
        hud = HUD(kind: kind, level: level ?? volume, muted: kind == .volume && muted)
        hideHUD?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hud = nil }
        }
        hideHUD = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    private func updateTap() {
        if replaceSystemHUD, tap == nil {
            // Media keys arrive as "system defined" events (NX_SYSDEFINED).
            let mask = CGEventMask(1 << 14)
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                               options: .defaultTap, eventsOfInterest: mask,
                                               callback: mediaKeyCallback,
                                               userInfo: Unmanaged.passUnretained(self).toOpaque())
            else { return } // No Accessibility access yet.
            tap = port
            tapSource = CFMachPortCreateRunLoopSource(nil, port, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
        } else if !replaceSystemHUD, let port = tap {
            CGEvent.tapEnable(tap: port, enable: false)
            if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
            tap = nil
            tapSource = nil
        }
    }

    /// Accessibility may be granted after launch: try again.
    func retryTapIfNeeded() {
        if replaceSystemHUD && tap == nil { updateTap() }
    }

    fileprivate func reenableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }
}

private let mediaKeyCallback: CGEventTapCallBack = { _, type, event, info in
    guard let info else { return Unmanaged.passUnretained(event) }
    let controls = Unmanaged<SystemControls>.fromOpaque(info).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { controls.reenableTap() }
        return Unmanaged.passUnretained(event)
    }
    guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }
    let data = ns.data1
    let code = (data & 0xFFFF_0000) >> 16
    let down = ((data & 0xFF00) >> 8) == 0xA
    let fine = ns.modifierFlags.contains([.option, .shift])
    let handled = MainActor.assumeIsolated { controls.handleKey(code, down: down, fine: fine) }
    return handled ? nil : Unmanaged.passUnretained(event)
}
