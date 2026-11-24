import AppKit
import Combine
import SwiftUI

/// Puts the island over the notch of the built-in display and drives it:
/// it grows a little under the pointer, opens on a click and closes when the
/// pointer leaves it.
@MainActor
final class IslandController {
    let island = IslandModel()
    let calendar = CalendarStore()
    let nowPlaying = NowPlaying()
    let controls: SystemControls
    let alerts = IslandAlerts()
    let fichaje = Fichaje()

    var enabled: Bool {
        didSet { rebuild() }
    }

    private var panel: IslandPanel?
    /// The notch, in screen coordinates.
    private var notchRect: CGRect = .zero
    private var monitors: [Any] = []
    private var subscriptions: Set<AnyCancellable> = []
    private var retryTimer: Timer?
    /// Horizontal scroll gathered while open, to switch pages.
    private var scrollX: CGFloat = 0
    private var swiped = false
    /// `-IslandDebugState open` keeps the island open, to check its look.
    private let pinnedOpen = UserDefaults.standard.string(forKey: "IslandDebugState") == "open"

    private static let openSpring = Animation.spring(response: 0.36, dampingFraction: 0.76)
    private static let closeSpring = Animation.spring(response: 0.32, dampingFraction: 0.84)
    private static let hoverSpring = Animation.spring(response: 0.26, dampingFraction: 0.68)
    /// Indicators and alerts growing out of the notch and back: slower and
    /// without the bounce, so they glide rather than pop.
    private static let compactSpring = Animation.spring(response: 0.5, dampingFraction: 0.9)

    init(enabled: Bool, replaceSystemHUD: Bool) {
        self.enabled = enabled
        controls = SystemControls(replaceSystemHUD: replaceSystemHUD)
        island.onTap = { [weak self] in self?.open() }

        // What the closed island shows: an indicator first, then an alert,
        // then the music, then the running workday.
        Publishers.CombineLatest4(controls.$hud, alerts.$alert, nowPlaying.$visible, fichaje.$live)
            .sink { [weak self] hud, alert, playing, working in
                let compact: IslandModel.Compact = hud != nil ? .hud : alert != nil ? .alert
                    : playing ? .nowPlaying : working ? .fichaje : .none
                let wings: IslandModel.Wings
                switch compact {
                case .none: wings = .none
                case .hud: wings = LevelHUD.wings
                case .alert: wings = alert.map(AlertView.wings(for:)) ?? .none
                case .nowPlaying: wings = IslandModel.Wings(left: 32, right: 32)
                case .fichaje: wings = CompactFichaje.wings
                }
                MainActor.assumeIsolated { self?.setCompact(compact, wings: wings) }
            }
            .store(in: &subscriptions)
        nowPlaying.$visible
            .sink { [weak self] playing in
                MainActor.assumeIsolated {
                    guard let self, !playing, self.island.page == .player else { return }
                    withAnimation(Self.openSpring) { self.island.page = self.pages.first ?? .calendar }
                }
            }
            .store(in: &subscriptions)
        // Accessibility may be granted while running.
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.controls.retryTapIfNeeded() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        rebuild()
    }

    private func rebuild() {
        guard enabled, let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea
        else {
            tearDown()
            return
        }

        let height = screen.safeAreaInsets.top
        notchRect = CGRect(x: left.maxX, y: screen.frame.maxY - height, width: right.minX - left.maxX, height: height)
        island.notch = notchRect.size

        // Room around the open island for its shadow and the blurred halo.
        let openSize = IslandModel.maxOpenSize
        let size = CGSize(width: openSize.width + 2 * IslandModel.maxFlare + 200, height: openSize.height + 90)
        let frame = CGRect(x: notchRect.midX - size.width / 2, y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)

        if let panel {
            panel.setFrame(frame, display: true)
        } else {
            let panel = IslandPanel(frame: frame)
            let host = IslandHostingView(rootView: IslandView(island: island, calendar: calendar, nowPlaying: nowPlaying,
                                                            controls: controls, alerts: alerts, fichaje: fichaje))
            host.frame = CGRect(origin: .zero, size: frame.size)
            panel.contentView = host
            panel.orderFrontRegardless()
            self.panel = panel
            installMonitors()
        }

        if pinnedOpen { open() }
    }

    private func tearDown() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel?.orderOut(nil)
        panel = nil
        island.state = .closed
    }

    private func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) { monitors.append(m) }
        // A click anywhere else closes it.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(m) }
        // A sideways swipe on the open island switches between the player
        // and the calendar.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.scrolled(event) }
            return event
        }) { monitors.append(m) }
    }

    /// The island's current outline in screen coordinates, with a little slack
    /// so the pointer doesn't flicker it at the edges.
    private func activeRect() -> CGRect {
        let size = island.size(for: island.state)
        let slack: CGFloat = island.state == .open ? 8 : 4
        return CGRect(x: notchRect.midX - size.width / 2, y: notchRect.maxY - size.height,
                      width: size.width, height: size.height).insetBy(dx: -slack, dy: -slack)
    }

    private func pointerMoved() {
        guard let panel else { return }
        let inside = activeRect().contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !inside
        switch (island.state, inside) {
        case (.closed, true):
            withAnimation(Self.hoverSpring) { island.state = .hover }
        case (.hover, false), (.open, false):
            close()
        default:
            break
        }
    }

    private func open() {
        guard island.state != .open else { return }
        calendar.refresh()
        controls.suppressHUD = true
        fichaje.refresh()
        // Music first, then a running workday, else the calendar.
        island.page = nowPlaying.visible ? .player : fichaje.live ? .fichaje : .calendar
        island.showsVolume = false
        withAnimation(Self.openSpring) { island.state = .open }
    }

    private func close() {
        guard island.state != .closed, !pinnedOpen else { return }
        withAnimation(Self.closeSpring) { island.state = .closed }
        controls.suppressHUD = false
        panel?.ignoresMouseEvents = true
    }

    /// The open island's pages, in swipe order: the player while there is
    /// music, the workday once connected, and the calendar.
    private var pages: [IslandModel.Page] {
        var all: [IslandModel.Page] = []
        if nowPlaying.visible { all.append(.player) }
        if fichaje.connected { all.append(.fichaje) }
        all.append(.calendar)
        return all
    }

    private func setCompact(_ compact: IslandModel.Compact, wings: IslandModel.Wings) {
        guard compact != island.compact || wings != island.wings else { return }
        withAnimation(Self.compactSpring) {
            island.compact = compact
            island.wings = wings
        }
    }

    private func scrolled(_ event: NSEvent) {
        guard island.state == .open, pages.count > 1, event.momentumPhase.isEmpty else { return }
        if event.phase == .began { scrollX = 0; swiped = false }
        scrollX += event.scrollingDeltaX
        // One page per swipe.
        guard !swiped, abs(scrollX) > 40 else { return }
        swiped = true
        // Swiping left goes to the next page, right to the previous one.
        let all = pages
        let index = all.firstIndex(of: island.page) ?? 0
        let next = all[(index + (scrollX < 0 ? 1 : all.count - 1)) % all.count]
        if next == .calendar { calendar.refresh() }
        if next == .fichaje { fichaje.refresh() }
        withAnimation(Self.openSpring) {
            island.showsVolume = false
            island.page = next
        }
    }
}

/// A borderless panel above the menu bar that never takes focus.
private final class IslandPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Windows are normally kept below the menu bar; this one sits over it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Reacts to the first click even though MagGlow is never the active app.
private final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
