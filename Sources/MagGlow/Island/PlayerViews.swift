import AppKit
import SwiftUI

// MARK: - Compact (closed island)

/// Content for the closed island: one view per wing, with the notch's width
/// left empty between them, since the camera housing hides anything there.
/// Left content hugs the island's left edge, right content its right edge.
struct WingsLayout<Left: View, Right: View>: View {
    let wings: IslandModel.Wings
    let notch: CGFloat
    var inset: CGFloat = 12
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right

    var body: some View {
        HStack(spacing: 0) {
            left.padding(.leading, inset).frame(width: wings.left, alignment: .leading)
            Color.clear.frame(width: notch)
            right.padding(.trailing, inset - 1).frame(width: wings.right, alignment: .trailing)
        }
    }
}

/// The closed island while music plays: the artwork on the left wing and a
/// level meter in the album's colour on the right one. Under the pointer the
/// meter turns into a play/pause button.
struct CompactPlayer: View {
    @ObservedObject var nowPlaying: NowPlaying
    let hovering: Bool
    let wings: IslandModel.Wings
    let notch: CGFloat

    var body: some View {
        let art: CGFloat = hovering ? 22 : 20
        WingsLayout(wings: wings, notch: notch, inset: 7) {
            Artwork(image: nowPlaying.artwork, size: art, radius: 5)
                .opacity(nowPlaying.playing ? 1 : 0.5)
        } right: {
            ZStack {
                if hovering {
                    Button(action: nowPlaying.playPause) {
                        Image(systemName: nowPlaying.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Glow())
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .transition(.blurFade)
                } else if nowPlaying.playing {
                    LevelMeter(playing: true, color: Color(nsColor: nowPlaying.tint), size: CGSize(width: 17, height: 12))
                        .transition(.blurFade)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .background(Glow())
                        .transition(.blurFade)
                }
            }
            .frame(width: 26, height: 26)
        }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .animation(.easeOut(duration: 0.18), value: nowPlaying.playing)
    }
}

/// A soft white halo behind a control.
private struct Glow: View {
    var body: some View {
        RadialGradient(colors: [.white.opacity(0.28), .white.opacity(0)], center: .center, startRadius: 0, endRadius: 15)
            .frame(width: 34, height: 34)
            .allowsHitTesting(false)
    }
}

// MARK: - Open island

/// The open island's player: artwork, title, progress, controls and, from the
/// output button, a volume slider.
struct PlayerView: View {
    @ObservedObject var nowPlaying: NowPlaying
    @ObservedObject var controls: SystemControls
    @ObservedObject var island: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            header
            progress
                .padding(.top, 13)
            buttons
                .padding(.top, 14)
            if island.showsVolume {
                volume
                    .padding(.top, 12)
                    .transition(.blurFade)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
    }

    /// The top of the panel sits behind the physical notch: nothing may go
    /// in the band it covers. The artwork stays left of it, and the title
    /// starts below it.
    private var header: some View {
        let top: CGFloat = 19
        let notchLeft = (IslandModel.playerSize.width - island.notch.width) / 2
        let art = min(55, notchLeft - 18 - 6)
        let textTop = max(island.notch.height + 3 - top, 0)
        return HStack(alignment: .top, spacing: 15) {
            Button(action: nowPlaying.openPlayer) {
                Artwork(image: nowPlaying.artwork, size: art, radius: 9)
                    .opacity(nowPlaying.playing ? 1 : 0.55)
                    .scaleEffect(nowPlaying.playing ? 1 : 0.94)
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: nowPlaying.playing)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(nowPlaying.track?.title ?? "")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(nowPlaying.track?.artist ?? "")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1)
            .padding(.top, textTop)
            Spacer(minLength: 8)
            LevelMeter(playing: nowPlaying.playing, color: Color(nsColor: nowPlaying.tint),
                       size: CGSize(width: 22, height: 16))
                .padding(.trailing, 4)
                .padding(.top, 6)
        }
        .padding(.top, top)
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let elapsed = nowPlaying.elapsed(at: context.date)
            let duration = max(nowPlaying.track?.duration ?? 0, 1)
            HStack(spacing: 10) {
                Text(Self.time(elapsed))
                    .frame(width: 30, alignment: .leading)
                Scrubber(value: elapsed / duration, height: 6) { nowPlaying.seek(to: $0 * duration) }
                Text("-" + Self.time(duration - elapsed))
                    .frame(width: 34, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.45))
        }
    }

    private var buttons: some View {
        HStack(spacing: 0) {
            control("shuffle", size: 15, dim: !nowPlaying.shuffle, action: nowPlaying.toggleShuffle)
            Spacer(minLength: 0)
            control("backward.fill", size: 19, action: nowPlaying.previous)
            Spacer(minLength: 0)
            control(nowPlaying.playing ? "pause.fill" : "play.fill", size: 25, action: nowPlaying.playPause)
                .contentTransition(.symbolEffect(.replace))
            Spacer(minLength: 0)
            control("forward.fill", size: 19, action: nowPlaying.next)
            Spacer(minLength: 0)
            Button {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.8)) { island.showsVolume.toggle() }
            } label: {
                Image(systemName: controls.outputSymbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(island.showsVolume ? 0.85 : 0.5))
                    .frame(width: 46, height: 46)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.white.opacity(island.showsVolume ? 0.1 : 0)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(height: 46)
        .padding(.horizontal, -8)
    }

    private func control(_ symbol: String, size: CGFloat, dim: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(dim ? 0.45 : 1))
                .frame(width: 46, height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private var volume: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 10))
            Scrubber(value: Double(controls.muted ? 0 : controls.volume), height: 6, live: true) {
                controls.setVolume(Float($0))
            }
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 10))
        }
        .foregroundStyle(.white.opacity(0.45))
    }

    static func time(_ seconds: Double) -> String {
        let s = max(Int(seconds.rounded(.down)), 0)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Shrinks a control a little while pressed.
private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// A rounded bar that can be clicked or dragged. `live` reports every move;
/// otherwise only where the drag ends (seeking on every move would stutter).
private struct Scrubber: View {
    let value: Double
    let height: CGFloat
    var live = false
    let onChange: (Double) -> Void

    @State private var dragging: Double?

    var body: some View {
        GeometryReader { geo in
            let shown = min(max(dragging ?? value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule().fill(.white.opacity(dragging == nil ? 0.5 : 0.75))
                    .frame(width: max(geo.size.width * shown, height))
            }
            .frame(height: dragging == nil ? height : height + 2)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let v = min(max(g.location.x / geo.size.width, 0), 1)
                    dragging = v
                    if live { onChange(v) }
                }
                .onEnded { g in
                    onChange(min(max(g.location.x / geo.size.width, 0), 1))
                    dragging = nil
                })
            .animation(.easeOut(duration: 0.15), value: dragging == nil)
        }
        .frame(height: 16)
    }
}

// MARK: - Shared pieces

/// Album artwork with rounded corners, or a placeholder note.
struct Artwork: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.1)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.45, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Five bars bouncing to the music; dots while paused.
struct LevelMeter: View {
    let playing: Bool
    let color: Color
    let size: CGSize

    private static let speeds: [Double] = [6.1, 8.3, 5.2, 7.4, 9.0]
    private static let phases: [Double] = [0, 1.3, 2.1, 0.7, 2.8]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let bar = max(size.width / 9, 2)
            HStack(alignment: .center, spacing: (size.width - 5 * bar) / 4) {
                ForEach(0..<5, id: \.self) { i in
                    let wave = abs(sin(t * Self.speeds[i] + Self.phases[i])) * 0.6
                        + abs(sin(t * Self.speeds[i] * 0.37 + Self.phases[i])) * 0.4
                    Capsule()
                        .fill(color)
                        .frame(width: bar, height: playing ? max(size.height * (0.22 + 0.78 * wave), bar) : bar)
                }
            }
            .frame(width: size.width, height: size.height)
            .animation(.easeOut(duration: 0.25), value: playing)
        }
    }
}

// MARK: - Volume and brightness indicator

/// Replaces the system's volume and brightness indicator: the icon and name
/// on the left wing, the level on the right one.
struct LevelHUD: View {
    let hud: SystemControls.HUD
    let wings: IslandModel.Wings
    let notch: CGFloat

    /// Room for the bar on the right, and the same on the left so the island
    /// stays centred on the notch.
    static let wings = IslandModel.Wings(left: 90, right: 90)

    var body: some View {
        WingsLayout(wings: wings, notch: notch) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
        } right: {
            GlowBar(level: CGFloat(min(max(hud.level, 0), 1)), color: barColor, dimmed: hud.muted)
                .frame(width: 66, height: 5)
                .animation(.spring(response: 0.25, dampingFraction: 0.9), value: hud.level)
        }
    }

    /// Brightness is white. Sound goes from green through orange to red as
    /// it gets louder, like a level meter in decibels.
    private var barColor: Color {
        guard hud.kind == .volume else { return .white }
        let green = (0.36, 0.84, 0.53), orange = (0.96, 0.56, 0.33), red = (0.94, 0.27, 0.36)
        func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> Color {
            Color(red: a.0 + (b.0 - a.0) * t, green: a.1 + (b.1 - a.1) * t, blue: a.2 + (b.2 - a.2) * t)
        }
        let v = Double(hud.level)
        if v <= 0.55 { return mix(green, green, 0) }
        if v <= 0.82 { return mix(green, orange, (v - 0.55) / 0.27) }
        return mix(orange, red, min((v - 0.82) / 0.18, 1))
    }
}

/// A level bar whose fill glows, brightest at its tip.
private struct GlowBar: View {
    let level: CGFloat
    let color: Color
    let dimmed: Bool

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let width = max(geo.size.width * level, level > 0 ? height : 0)
            Capsule()
                .fill(color == .white ? Color.white.opacity(0.2) : color.opacity(0.22))
                .frame(width: geo.size.width, height: height)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(color.opacity(dimmed ? 0.35 : 1))
                        .frame(width: width, height: height)
                        .shadow(color: color.opacity(dimmed ? 0 : 0.35), radius: 2)
                }
                // The glow at the tip, drawn over the bar without making it
                // any taller.
                .overlay(alignment: .leading) {
                    Ellipse()
                        .fill(color)
                        .frame(width: 14, height: 7)
                        .blur(radius: 3.5)
                        .opacity(dimmed || level == 0 ? 0 : 0.6)
                        .offset(x: width - 11)
                        .allowsHitTesting(false)
                }
        }
    }
}

extension LevelHUD {

    private var symbol: String {
        if hud.kind == .brightness { return hud.level < 0.5 ? "sun.min.fill" : "sun.max.fill" }
        if hud.muted || hud.level == 0 { return "speaker.slash.fill" }
        if hud.level < 0.34 { return "speaker.wave.1.fill" }
        if hud.level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}
