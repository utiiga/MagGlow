import AppKit
import SwiftUI

/// What Music or Spotify is playing, read and controlled with AppleScript.
///
/// macOS no longer lets third-party apps read the system's "Now Playing"
/// info, so this talks to the two players directly: each announces changes
/// with a distributed notification, and AppleScript fills in the details
/// (position, artwork, shuffle) and sends the commands.
@MainActor
final class NowPlaying: ObservableObject {
    enum Player: String, CaseIterable {
        case music = "com.apple.Music"
        case spotify = "com.spotify.client"

        var notification: String {
            switch self {
            case .music: return "com.apple.Music.playerInfo"
            case .spotify: return "com.spotify.client.PlaybackStateChanged"
            }
        }
    }

    struct Track: Equatable {
        var title: String
        var artist: String
        var album: String
        var duration: Double
    }

    @Published private(set) var player: Player?
    @Published private(set) var track: Track?
    @Published private(set) var playing = false
    @Published private(set) var shuffle = false
    @Published private(set) var artwork: NSImage?
    /// The artwork's dominant colour, brightened, for the level meter.
    @Published private(set) var tint = NSColor.white
    /// Something to show: a track that is playing, or paused not long ago.
    @Published private(set) var visible = false

    private var position: Double = 0
    private var positionDate = Date()
    private var pausedAt: Date?
    private var artworkKey: String?
    private var resync: Timer?
    /// AppleScript runs off the main thread, always on this one queue.
    private let scripts = DispatchQueue(label: "com.magglow.nowplaying")

    /// How long a paused track stays in the island.
    private static let pausedTimeout: TimeInterval = 5 * 60

    init() {
        let center = DistributedNotificationCenter.default()
        for p in Player.allCases {
            center.addObserver(forName: Notification.Name(p.notification), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(p) }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, let id, id == self.player?.rawValue else { return }
                self.clear()
            }
        }
        resync = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.periodic() }
        }
        for p in Player.allCases where Self.isRunning(p) { refresh(p) }
    }

    func elapsed(at date: Date) -> Double {
        guard let track else { return 0 }
        let value = position + (playing ? date.timeIntervalSince(positionDate) : 0)
        return min(max(value, 0), max(track.duration, 0))
    }

    // MARK: Commands

    func playPause() {
        playing.toggle()
        position = elapsed(at: Date()) // freeze or restart the local clock
        positionDate = Date()
        pausedAt = playing ? nil : Date()
        send("playpause")
    }

    func next() { send("next track") }
    func previous() { send("previous track") }

    func toggleShuffle() {
        guard let player else { return }
        shuffle.toggle()
        switch player {
        case .music: send("set shuffle enabled to not shuffle enabled")
        case .spotify: send("set shuffling to not shuffling")
        }
    }

    func seek(to seconds: Double) {
        position = seconds
        positionDate = Date()
        send("set player position to \(String(format: "%.2f", seconds))")
    }

    func openPlayer() {
        guard let player, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.rawValue) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    // MARK: Reading

    private func send(_ command: String) {
        guard let player, Self.isRunning(player) else { return }
        let source = "tell application id \"\(player.rawValue)\" to \(command)"
        scripts.async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated { self?.refresh(player) }
            }
        }
    }

    private func periodic() {
        if let player, Self.isRunning(player) {
            refresh(player)
        } else if player != nil {
            clear()
        }
        updateVisible()
    }

    private static func isRunning(_ player: Player) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: player.rawValue).isEmpty
    }

    private static let separator = "\u{1E}"

    private static func infoScript(_ player: Player) -> String {
        let sep = "(character id 30)"
        switch player {
        case .music:
            return """
            tell application id "com.apple.Music"
                if player state is stopped then return "stopped"
                set t to current track
                return (player state as string) & \(sep) & (name of t) & \(sep) & (artist of t) & \(sep) & (album of t) & \(sep) & (duration of t as string) & \(sep) & (player position as string) & \(sep) & (shuffle enabled as string)
            end tell
            """
        case .spotify:
            return """
            tell application id "com.spotify.client"
                if player state is stopped then return "stopped"
                set t to current track
                return (player state as string) & \(sep) & (name of t) & \(sep) & (artist of t) & \(sep) & (album of t) & \(sep) & ((duration of t) / 1000 as string) & \(sep) & (player position as string) & \(sep) & (shuffling as string) & \(sep) & (artwork url of t)
            end tell
            """
        }
    }

    private func refresh(_ source: Player) {
        guard Self.isRunning(source) else { return }
        let script = Self.infoScript(source)
        scripts.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.apply(result, from: source) }
            }
        }
    }

    private func apply(_ result: String?, from source: Player) {
        guard let result else { return }
        let parts = result.components(separatedBy: Self.separator)
        guard parts.count >= 7 else {
            // Stopped: forget it, unless the other player is the one shown.
            if player == source { clear() }
            return
        }
        let isPlaying = parts[0] == "playing"
        // Don't let a paused player take the island from one that is playing.
        if let player, player != source, playing, !isPlaying { return }

        func number(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        let newTrack = Track(title: parts[1], artist: parts[2], album: parts[3], duration: number(parts[4]))

        player = source
        if track != newTrack { track = newTrack }
        if playing != isPlaying {
            playing = isPlaying
            pausedAt = isPlaying ? nil : Date()
        }
        position = number(parts[5])
        positionDate = Date()
        shuffle = parts[6] == "true"
        updateVisible()

        let key = "\(source.rawValue)|\(newTrack.title)|\(newTrack.artist)|\(newTrack.album)"
        if key != artworkKey {
            artworkKey = key
            loadArtwork(source, url: parts.count > 7 ? parts[7] : nil, key: key)
        }
    }

    private func loadArtwork(_ source: Player, url: String?, key: String) {
        let deliver: @Sendable (Data?) -> Void = { data in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.artworkKey == key else { return }
                    let image = data.flatMap(NSImage.init(data:))
                    self.artwork = image
                    self.tint = image.map(Self.dominantColor) ?? .white
                }
            }
        }
        switch source {
        case .music:
            scripts.async {
                var error: NSDictionary?
                let descriptor = NSAppleScript(source: """
                    tell application id "com.apple.Music" to get raw data of artwork 1 of current track
                    """)?.executeAndReturnError(&error)
                deliver(descriptor?.data)
            }
        case .spotify:
            guard let url, let link = URL(string: url) else { return deliver(nil) }
            URLSession.shared.dataTask(with: link) { data, _, _ in deliver(data) }.resume()
        }
    }

    private func clear() {
        player = nil
        track = nil
        playing = false
        artwork = nil
        artworkKey = nil
        tint = .white
        updateVisible()
    }

    private func updateVisible() {
        let show: Bool
        if track == nil {
            show = false
        } else if playing {
            show = true
        } else {
            show = Date().timeIntervalSince(pausedAt ?? .distantPast) < Self.pausedTimeout
        }
        if show != visible { visible = show }
    }

    /// The artwork's average colour, pushed to a vivid, light version so the
    /// meter reads on black, as the album's colour rather than a grey.
    private static func dominantColor(_ image: NSImage) -> NSColor {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)
        guard let rep else { return .white }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .medium
        image.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        NSGraphicsContext.restoreGraphicsState()
        guard let color = rep.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else { return .white }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.08 { return NSColor(white: 0.85, alpha: 1) } // greyscale art: stay neutral
        return NSColor(hue: h, saturation: min(max(s, 0.55), 0.8), brightness: max(b, 0.82), alpha: 1)
    }
}
