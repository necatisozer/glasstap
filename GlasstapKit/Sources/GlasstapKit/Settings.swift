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
    public var wdaURL: URL

    public init(encoder: EncoderSettings, controlPort: UInt16, videoPort: UInt16, wdaURL: URL) {
        self.encoder = encoder
        self.controlPort = controlPort
        self.videoPort = videoPort
        self.wdaURL = wdaURL
    }

    public static let defaults = GlasstapSettings(
        encoder: EncoderSettings(codec: .hevc, width: 590, bitrate: 800_000, fps: 30),
        controlPort: 9300,
        videoPort: 9301,
        wdaURL: URL(string: "http://127.0.0.1:8100")!)
}

/// The settings as the user types them, in the units of the settings window.
public struct SettingsInput: Sendable, Equatable {
    public var codec: VideoCodec
    public var width: Int
    public var bitrateKbps: Int
    public var fps: Int
    public var controlPort: Int
    public var videoPort: Int
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
        wdaURL = s.wdaURL.absoluteString
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
        guard let url = URL(string: wdaURL.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil
        else { return problem("The WDA URL must be an http URL, such as http://127.0.0.1:8100.") }
        return .success(GlasstapSettings(
            encoder: EncoderSettings(codec: codec, width: width, bitrate: bitrateKbps * 1000, fps: fps),
            controlPort: UInt16(controlPort), videoPort: UInt16(videoPort), wdaURL: url))
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
