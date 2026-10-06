import Foundation

public enum VideoCodec: String, Sendable, CaseIterable, Codable {
    case hevc
    case h264

    public var displayName: String {
        switch self {
        case .hevc: "H.265"
        case .h264: "H.264"
        }
    }
}

/// What the encoder needs. A change restarts the capture.
public struct EncoderSettings: Sendable, Equatable, Codable {
    public var codec: VideoCodec
    /// The output width in pixels. The height follows the aspect ratio of the screen.
    public var width: Int
    /// Bits per second.
    public var bitrate: Int
    public var fps: Int

    public init(codec: VideoCodec, width: Int, bitrate: Int, fps: Int) {
        self.codec = codec
        self.width = width
        self.bitrate = bitrate
        self.fps = fps
    }
}

/// Settings that passed `SettingsInput.validate()`.
public struct GlasstapSettings: Sendable, Equatable, Codable {
    public var encoder: EncoderSettings
    public var controlPort: UInt16
    public var videoPort: UInt16
    /// The Apple team that signs WDA. Empty until the user sets it.
    public var teamID: String
    /// The WDA runner's bundle id without ".xctrunner". Empty means the default for the team.
    public var wdaBundlePrefix: String
    /// A WDA that the user runs. nil means that glasstap builds and starts WDA itself.
    public var wdaURLOverride: URL?

    public init(encoder: EncoderSettings, controlPort: UInt16, videoPort: UInt16,
                teamID: String = "", wdaBundlePrefix: String = "", wdaURLOverride: URL? = nil) {
        self.encoder = encoder
        self.controlPort = controlPort
        self.videoPort = videoPort
        self.teamID = teamID
        self.wdaBundlePrefix = wdaBundlePrefix
        self.wdaURLOverride = wdaURLOverride
    }

    public static let defaults = GlasstapSettings(
        encoder: EncoderSettings(codec: .hevc, width: 590, bitrate: 800_000, fps: 30),
        controlPort: 9300,
        videoPort: 9301)

    /// The signing for WDA, once a team is set.
    public var wdaSigning: WDASigning? {
        guard !teamID.isEmpty else { return nil }
        return WDASigning(teamID: teamID, bundlePrefix: wdaBundlePrefix.isEmpty
            ? WDASigning.defaultBundlePrefix(teamID: teamID) : wdaBundlePrefix)
    }

    private enum CodingKeys: String, CodingKey {
        case encoder, controlPort, videoPort, teamID, wdaBundlePrefix, wdaURLOverride
    }

    /// Settings saved by an older version lack the newer keys, and keep their other values.
    /// The old `wdaURL` key pointed at a forwarder that glasstap no longer uses, so it is not read.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        encoder = try c.decode(EncoderSettings.self, forKey: .encoder)
        controlPort = try c.decode(UInt16.self, forKey: .controlPort)
        videoPort = try c.decode(UInt16.self, forKey: .videoPort)
        teamID = try c.decodeIfPresent(String.self, forKey: .teamID) ?? ""
        wdaBundlePrefix = try c.decodeIfPresent(String.self, forKey: .wdaBundlePrefix) ?? ""
        wdaURLOverride = try c.decodeIfPresent(URL.self, forKey: .wdaURLOverride)
    }
}

/// The settings as the user types them, in the units of the settings window.
public struct SettingsInput: Sendable, Equatable {
    public var codec: VideoCodec
    public var width: Int
    public var bitrateKbps: Int
    public var fps: Int
    public var controlPort: Int
    public var videoPort: Int
    public var teamID: String
    public var wdaBundlePrefix: String
    /// Empty for automatic.
    public var wdaURL: String

    static let widthRange = 160...2000
    static let bitrateKbpsRange = 100...20_000
    static let fpsRange = 1...60
    static let portRange = 1024...65535

    public init(_ s: GlasstapSettings) {
        codec = s.encoder.codec
        width = s.encoder.width
        bitrateKbps = s.encoder.bitrate / 1000
        fps = s.encoder.fps
        controlPort = Int(s.controlPort)
        videoPort = Int(s.videoPort)
        teamID = s.teamID
        wdaBundlePrefix = s.wdaBundlePrefix
        wdaURL = s.wdaURLOverride?.absoluteString ?? ""
    }

    /// The settings, or a message that says what to correct.
    public func validate() -> Result<GlasstapSettings, SettingsProblem> {
        func problem(_ message: String) -> Result<GlasstapSettings, SettingsProblem> { .failure(SettingsProblem(message: message)) }
        let r = Self.self
        guard r.widthRange.contains(width) else {
            return problem("The width must be \(r.widthRange.lowerBound)–\(r.widthRange.upperBound) px.")
        }
        // Checked before the conversion to bit/s, so the multiplication cannot overflow.
        guard r.bitrateKbpsRange.contains(bitrateKbps) else {
            return problem("The bitrate must be \(r.bitrateKbpsRange.lowerBound)–\(r.bitrateKbpsRange.upperBound) kbit/s.")
        }
        guard r.fpsRange.contains(fps) else {
            return problem("The frame rate must be \(r.fpsRange.lowerBound)–\(r.fpsRange.upperBound) fps.")
        }
        guard r.portRange.contains(controlPort), r.portRange.contains(videoPort) else {
            return problem("A port must be \(r.portRange.lowerBound)–\(r.portRange.upperBound).")
        }
        guard controlPort != videoPort else { return problem("The two ports must differ.") }
        // Team and prefix go into an xcconfig file and a folder name, so only these characters pass.
        let team = teamID.trimmingCharacters(in: .whitespaces).uppercased()
        guard team.isEmpty || team.wholeMatch(of: /[A-Z0-9]{10}/) != nil else {
            return problem("The team id has 10 letters and digits, such as ABCDE12345.")
        }
        let prefix = wdaBundlePrefix.trimmingCharacters(in: .whitespaces)
        guard prefix.isEmpty || prefix.wholeMatch(of: /[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*/) != nil else {
            return problem("The bundle id prefix may hold only letters, digits, \"-\" and \".\", such as com.example.wda.")
        }
        let override = wdaURL.trimmingCharacters(in: .whitespaces)
        var url: URL?
        if !override.isEmpty {
            guard let parsed = URL(string: override), let scheme = parsed.scheme, ["http", "https"].contains(scheme),
                  parsed.host != nil
            else { return problem("The WDA URL must be empty or an http URL, such as http://127.0.0.1:8100.") }
            url = parsed
        }
        return .success(GlasstapSettings(
            encoder: EncoderSettings(codec: codec, width: width, bitrate: bitrateKbps * 1000, fps: fps),
            controlPort: UInt16(controlPort), videoPort: UInt16(videoPort),
            teamID: team, wdaBundlePrefix: prefix, wdaURLOverride: url))
    }
}

public struct SettingsProblem: Error, Equatable, Sendable {
    public let message: String
}

/// Keeps the settings in UserDefaults as one value.
public enum SettingsStore {
    static let key = "settings"

    /// The stored settings. A missing, unreadable or invalid value gives the defaults.
    public static func load(from defaults: UserDefaults = .standard) -> GlasstapSettings {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(GlasstapSettings.self, from: data),
              case .success(stored) = SettingsInput(stored).validate()
        else { return .defaults }
        return stored
    }

    public static func save(_ settings: GlasstapSettings, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
