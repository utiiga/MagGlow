import AppKit
import SwiftUI

/// What the island shows, and its size and corners in each state.
@MainActor
final class IslandModel: ObservableObject {
    enum State { case closed, hover, open }
    /// What the closed island shows on its wings, most urgent first.
    enum Compact: Equatable { case none, hud, alert, nowPlaying, fichaje }
    /// What the open island shows.
    enum Page { case calendar, player, fichaje }

    /// How far the island reaches past the notch on each side when closed.
    /// The middle is the notch itself, where nothing can be seen.
    struct Wings: Equatable {
        var left: CGFloat
        var right: CGFloat
        static let none = Wings(left: 0, right: 0)
    }

    @Published var state: State = .closed
    @Published var compact: Compact = .none
    @Published var wings = Wings.none
    @Published var page: Page = .calendar
    /// The player's volume slider is out.
    @Published var showsVolume = false
    /// The camera housing on this screen, so the closed island covers it.
    @Published var notch = CGSize(width: 208, height: 37.5)
    var onTap: () -> Void = {}

    static let calendarSize = CGSize(width: 350, height: 150)
    static let fichajeSize = CGSize(width: 350, height: 176)
    static let playerSize = CGSize(width: 370, height: 184)
    static let playerVolumeHeight: CGFloat = 214
    /// The tallest the island gets, to size its window.
    static let maxOpenSize = CGSize(width: 370, height: playerVolumeHeight)
    /// The concave flare where the island's sides meet the top of the screen.
    static let maxFlare: CGFloat = 18

    var flare: CGFloat {
        switch state {
        case .closed: return 6
        case .hover: return 7
        case .open: return Self.maxFlare
        }
    }

    func size(for state: State) -> CGSize {
        switch state {
        case .closed: return closedSize
        case .hover: return CGSize(width: closedSize.width + 16, height: closedSize.height + 6)
        case .open:
            if page == .calendar { return Self.calendarSize }
            if page == .fichaje { return Self.fichajeSize }
            return CGSize(width: Self.playerSize.width,
                          height: showsVolume ? Self.playerVolumeHeight : Self.playerSize.height)
        }
    }

    /// The notch, with wings either side when there is something to show.
    private var closedSize: CGSize {
        CGSize(width: notch.width + wings.left + wings.right, height: notch.height)
    }

    /// The wings as drawn now: a little wider under the pointer.
    var currentWings: Wings {
        guard compact != .none, state == .hover else { return wings }
        return Wings(left: wings.left + 8, right: wings.right + 8)
    }


    var bottomRadius: CGFloat {
        switch state {
        case .closed: return 10
        case .hover: return 13
        case .open: return 32
        }
    }
}

/// The black island hanging from the top of the screen: the notch's shape,
/// with flared top corners and rounded bottom ones.
struct IslandShape: Shape {
    var bottomRadius: CGFloat
    var flare: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, flare) }
        set { bottomRadius = newValue.first; flare = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let f = flare
        let r = min(bottomRadius, (rect.width - 2 * f) / 2, rect.height - f)
        let left = rect.minX + f, right = rect.maxX - f
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: left, y: rect.minY + f), control: CGPoint(x: left, y: rect.minY))
        p.addLine(to: CGPoint(x: left, y: rect.maxY - r))
        p.addCurve(to: CGPoint(x: left + r, y: rect.maxY),
                   control1: CGPoint(x: left, y: rect.maxY - r * 0.45),
                   control2: CGPoint(x: left + r * 0.45, y: rect.maxY))
        p.addLine(to: CGPoint(x: right - r, y: rect.maxY))
        p.addCurve(to: CGPoint(x: right, y: rect.maxY - r),
                   control1: CGPoint(x: right - r * 0.45, y: rect.maxY),
                   control2: CGPoint(x: right, y: rect.maxY - r * 0.45))
        p.addLine(to: CGPoint(x: right, y: rect.minY + f))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

struct IslandView: View {
    @ObservedObject var island: IslandModel
    @ObservedObject var calendar: CalendarStore
    @ObservedObject var nowPlaying: NowPlaying
    @ObservedObject var controls: SystemControls
    @ObservedObject var alerts: IslandAlerts
    @ObservedObject var fichaje: Fichaje

    var body: some View {
        let size = island.size(for: island.state)
        let open = island.state == .open
        let shape = IslandShape(bottomRadius: island.bottomRadius, flare: island.flare)

        ZStack(alignment: .top) {
            // The page behind the open island goes soft, as if seen through
            // frosted glass, fading out away from its edges.
            if open {
                let halo = CGSize(width: size.width + 140, height: size.height + 60)
                BackdropBlur(size: halo, island: size)
                    .frame(width: halo.width, height: halo.height)
                    .transition(.opacity)
            }

            shape
                .fill(.black)
                .frame(width: size.width + 2 * island.flare, height: size.height)
                .shadow(color: .black.opacity(open ? 0.45 : island.state == .hover ? 0.3 : 0),
                        radius: open ? 22 : 7, y: open ? 8 : 3)
                .overlay(alignment: .top) {
                    ZStack(alignment: .top) {
                        if open {
                            openContent
                                .id(island.page)
                                .frame(width: size.width, height: size.height, alignment: .top)
                                .transition(.blurFade)
                        } else {
                            closedContent
                                .id(island.compact)
                                .frame(width: size.width, height: size.height)
                                .transition(.blurFade)
                        }
                    }
                }
                .contentShape(shape)
                .onTapGesture { island.onTap() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var openContent: some View {
        switch island.page {
        case .calendar: IslandContent(calendar: calendar)
        case .player: PlayerView(nowPlaying: nowPlaying, controls: controls, island: island)
        case .fichaje: FichajeView(fichaje: fichaje, island: island)
        }
    }

    @ViewBuilder
    private var closedContent: some View {
        switch island.compact {
        case .none:
            Color.clear
        case .hud:
            if let hud = controls.hud { LevelHUD(hud: hud, wings: island.currentWings, notch: island.notch.width) }
        case .alert:
            if let alert = alerts.alert { AlertView(alert: alert, wings: island.currentWings, notch: island.notch.width) }
        case .nowPlaying:
            CompactPlayer(nowPlaying: nowPlaying, hovering: island.state == .hover,
                          wings: island.currentWings, notch: island.notch.width)
        case .fichaje:
            CompactFichaje(fichaje: fichaje, wings: island.currentWings, notch: island.notch.width)
        }
    }
}

/// The open island: today on the left, the coming days on the right.
private struct IslandContent: View {
    @ObservedObject var calendar: CalendarStore
    private let now = Date()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            today
            Spacer(minLength: 0)
            upcoming
        }
        .padding(.top, 19)
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var today: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: calendar.openCalendar) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Self.weekday(now))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(red: 1, green: 0.27, blue: 0.33))
                    Text(now.formatted(.dateTime.day()))
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(.white)
                        .padding(.top, -2)
                }
            }
            .buttonStyle(.plain)

            Spacer().frame(height: 26)

            if calendar.today.isEmpty {
                Text("No events today")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Text("Your day is clear")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.28))
                    .padding(.top, 3)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(calendar.today.prefix(3)) { item in
                        HStack(spacing: 6) {
                            Capsule().fill(Color(nsColor: item.color)).frame(width: 3, height: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(1)
                                Text(item.allDay ? String(localized: "All day")
                                                 : item.start.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.35))
                            }
                        }
                    }
                }
                .frame(maxWidth: 150, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var upcoming: some View {
        switch calendar.access {
        case .denied:
            Button(action: calendar.openPrivacySettings) {
                Pill(text: String(localized: "Allow Calendar access"), symbol: "calendar.badge.exclamationmark",
                     color: .white)
            }
            .buttonStyle(.plain)
            .padding(.top, 22)
        default:
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(Array(calendar.upcoming.prefix(2).enumerated()), id: \.element.id) { index, day in
                    Text(Self.dayHeader(day.date))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, index == 0 ? 0 : 9)
                        .padding(.bottom, 5)
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(day.items.prefix(2)) { item in
                            Button(action: calendar.openCalendar) {
                                Pill(text: item.title, symbol: item.birthday ? "gift.fill" : "calendar",
                                     color: item.color)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(width: 162, alignment: .trailing)
        }
    }

    /// "TUE", or "MAR" in Spanish (without the abbreviation's dot).
    static func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated)).replacingOccurrences(of: ".", with: "").uppercased()
    }

    /// "SUN, 29"
    static func dayHeader(_ date: Date) -> String {
        "\(weekday(date)), \(date.formatted(.dateTime.day()))"
    }
}

/// One event: a calendar-tinted label in a dark capsule.
private struct Pill: View {
    let text: String
    let symbol: String
    let color: NSColor

    var body: some View {
        let tint = Color(nsColor: color.usingColorSpace(.sRGB)?.blended(withFraction: 0.45, of: .white) ?? color)
        HStack(spacing: 5) {
            ZStack {
                Circle().fill(tint.opacity(0.85))
                Image(systemName: symbol)
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(.black.opacity(0.75))
            }
            .frame(width: 10, height: 10)
            Text(text)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tint.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 3)
        .frame(width: 162, height: 16, alignment: .leading)
        .background(Capsule().fill(.white.opacity(0.08)))
    }
}

/// Blurs whatever is behind the island, with no tint: strong right around
/// it and fading out over about 90 pt, so the page goes gradually back into
/// focus. `size` is the whole halo; the island sits at its top centre.
private struct BackdropBlur: NSViewRepresentable {
    let size: CGSize
    let island: CGSize

    func makeNSView(context: Context) -> BackdropView { BackdropView(size: size, island: island) }
    func updateNSView(_ view: BackdropView, context: Context) { view.update(size: size, island: island) }
}

/// Core Animation backdrop layers with a plain gaussian blur. The system
/// materials (NSVisualEffectView) always add a tint, which washes the page
/// out instead of just softening it, so this uses the window server's blur
/// directly, and falls back to a material if that isn't available.
///
/// The blur is progressive: a few layers, each stronger and kept closer to
/// the island than the one before, so the page sharpens gradually with
/// distance instead of switching from blurred to sharp.
final class BackdropView: NSView {
    /// Blur radius, and how far from the island (pt) its mask is half
    /// opaque and how soft that edge is.
    private struct Stage { let radius: CGFloat; let edge: CGFloat; let feather: CGFloat }
    private static let stages = [
        Stage(radius: 1.5, edge: 26, feather: 22),
        Stage(radius: 3, edge: 12, feather: 14),
        Stage(radius: 5, edge: 2, feather: 8),
    ]

    private var size: CGSize = .zero
    private var island: CGSize = .zero
    private var layers: [(layer: CALayer, mask: CALayer, stage: Stage)] = []

    init(size: CGSize, island: CGSize) {
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        if let layerClass = NSClassFromString("CABackdropLayer") as? CALayer.Type {
            for stage in Self.stages {
                guard let blur = Self.gaussianBlur(radius: stage.radius) else { continue }
                let backdrop = layerClass.init()
                backdrop.setValue(true, forKey: "windowServerAware")
                backdrop.filters = [blur]
                let mask = CALayer()
                backdrop.mask = mask
                layer?.addSublayer(backdrop)
                layers.append((backdrop, mask, stage))
            }
        }
        if layers.isEmpty {
            let fallback = NSVisualEffectView(frame: bounds)
            fallback.material = .popover
            fallback.blendingMode = .behindWindow
            fallback.state = .active
            fallback.autoresizingMask = [.width, .height]
            fallback.wantsLayer = true
            let mask = CALayer()
            fallback.layer?.mask = mask
            addSubview(fallback)
            layers.append((fallback.layer!, mask, Self.stages[1]))
        }
        update(size: size, island: island)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(size: CGSize, island: CGSize) {
        guard size != self.size || island != self.island else { return }
        self.size = size
        self.island = island
        for entry in layers { entry.mask.contents = Self.mask(size: size, island: island, stage: entry.stage) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in layers {
            if entry.layer !== layer { entry.layer.frame = bounds }
            entry.mask.frame = bounds
        }
        CATransaction.commit()
    }

    private static func gaussianBlur(radius: CGFloat) -> NSObject? {
        guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
        let selector = NSSelectorFromString("filterWithType:")
        guard filterClass.responds(to: selector),
              let filter = filterClass.perform(selector, with: "gaussianBlur")?.takeUnretainedValue() as? NSObject
        else { return nil }
        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(true, forKey: "inputNormalizeEdges")
        return filter
    }

    /// The island's outline grown by `stage.edge`, its edge softened over
    /// `stage.feather`. Drawn as the blurred shadow of a shape kept off the
    /// canvas, so only the soft copy lands in the image. The shape runs past
    /// the top edge so the blur doesn't fade out under the menu bar.
    private static func mask(size: CGSize, island: CGSize, stage: Stage) -> CGImage? {
        let scale: CGFloat = 2
        guard size.width > 0, size.height > 0,
              let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)

        // Bottom-left origin: the island hangs from the top centre.
        let e = stage.edge
        let shape = CGRect(x: (size.width - island.width) / 2 - e, y: size.height - island.height - e,
                           width: island.width + 2 * e, height: island.height + e + 40)
        let offscreen: CGFloat = 20_000
        ctx.setShadow(offset: CGSize(width: offscreen * scale, height: 0), blur: stage.feather * scale,
                      color: CGColor(gray: 0, alpha: 1))
        ctx.translateBy(x: -offscreen, y: 0)
        ctx.addPath(CGPath(roundedRect: shape, cornerWidth: 32 + e, cornerHeight: 32 + e, transform: nil))
        ctx.fillPath()
        return ctx.makeImage()
    }
}

/// Content comes into focus as the island opens, and blurs away as it closes.
private struct BlurFade: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 14 : 0)
            .opacity(active ? 0 : 1)
            .scaleEffect(active ? 0.86 : 1, anchor: .top)
    }
}

extension AnyTransition {
    static var blurFade: AnyTransition {
        .modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
    }
}
