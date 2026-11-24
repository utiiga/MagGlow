import Foundation

/// Files the menu bar app and the root helper use to talk to each other.
/// The app (running as the user) writes `request.json`; the helper (root)
/// only reads it and publishes what it is doing in `status.json`.
public enum MagGlowPaths {
    public static let dir = URL(fileURLWithPath: "/Library/Application Support/MagGlow")
    public static let request = dir.appendingPathComponent("request.json")
    public static let status = dir.appendingPathComponent("status.json")
}

public struct MagGlowRequest: Codable, Equatable {
    /// Keep the Mac awake (lid closed included) on battery until this moment.
    public var awakeUntil: Date?
    /// The app saw the displays go to sleep.
    public var displayAsleep: Bool
    /// An external display is connected. With the lid closed the Mac is then
    /// in clamshell mode and the helper must not put the displays to sleep.
    public var externalDisplay: Bool

    public init(awakeUntil: Date? = nil, displayAsleep: Bool = false, externalDisplay: Bool = false) {
        self.awakeUntil = awakeUntil
        self.displayAsleep = displayAsleep
        self.externalDisplay = externalDisplay
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        awakeUntil = try c.decodeIfPresent(Date.self, forKey: .awakeUntil)
        displayAsleep = try c.decodeIfPresent(Bool.self, forKey: .displayAsleep) ?? false
        externalDisplay = try c.decodeIfPresent(Bool.self, forKey: .externalDisplay) ?? false
    }
}

public struct MagGlowStatus: Codable, Equatable {
    public var onPower: Bool
    public var sleepBlocked: Bool
    public var blinking: Bool
    public var updated: Date

    public init(onPower: Bool, sleepBlocked: Bool, blinking: Bool, updated: Date) {
        self.onPower = onPower
        self.sleepBlocked = sleepBlocked
        self.blinking = blinking
        self.updated = updated
    }
}

public extension JSONDecoder {
    static let magglow: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

public extension JSONEncoder {
    static let magglow: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
}
