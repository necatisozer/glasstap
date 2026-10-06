import Foundation
import Network

/// An Apple device as `xcrun devicectl` reports it.
public struct CoreDevice: Sendable, Equatable {
    public var udid: String
    public var name: String
    public var isPhysical: Bool
    /// "connected" while the CoreDevice tunnel is up.
    public var tunnelState: String?
    /// "wired" for USB, "localNetwork" for Wi-Fi.
    public var transportType: String?
    /// "paired" after the user trusted this Mac.
    public var pairingState: String?
    /// "enabled" when Developer Mode is on. Simulators have none.
    public var developerModeStatus: String?
    public var osVersion: String?
    /// The iPhone's IPv6 address in the CoreDevice tunnel. Only `device info details` reports it.
    public var tunnelIPAddress: String?

    public init(udid: String, name: String, isPhysical: Bool, tunnelState: String? = nil,
                transportType: String? = nil, pairingState: String? = nil,
                developerModeStatus: String? = nil, osVersion: String? = nil, tunnelIPAddress: String? = nil) {
        self.udid = udid
        self.name = name
        self.isPhysical = isPhysical
        self.tunnelState = tunnelState
        self.transportType = transportType
        self.pairingState = pairingState
        self.developerModeStatus = developerModeStatus
        self.osVersion = osVersion
        self.tunnelIPAddress = tunnelIPAddress
    }

    /// Whether glasstap can use the iPhone. A paired iPhone on USB counts while its tunnel is down:
    /// the tunnel of an idle iPhone stays "disconnected" until a devicectl command or xcodebuild uses it.
    public var isReachable: Bool {
        Devicectl.usableTunnelStates.contains(tunnelState ?? "") || (transportType == "wired" && pairingState == "paired")
    }

    public var osMajorVersion: Int? {
        osVersion?.split(separator: ".").first.flatMap { Int($0) }
    }
}

/// Why a capture device has no usable CoreDevice.
public enum DeviceProblem: Error, Hashable, Sendable {
    case notPaired
    case duplicateName(String)
    case developerModeOff(String)
    case lookupFailed(String)

    public var message: String {
        switch self {
        case .notPaired: "iPhone not paired or not trusted"
        case let .duplicateName(name): "Two iPhones are named \(name). Rename one in Settings > General > About."
        case .developerModeOff: "Developer Mode is off"
        case let .lookupFailed(reason): "devicectl failed: \(reason)"
        }
    }

    public var hint: String? {
        switch self {
        case .notPaired: "Unlock the iPhone, and tap Trust when it asks about this Mac."
        case .duplicateName: nil
        case .developerModeOff: "On the iPhone, open Settings > Privacy & Security > Developer Mode, turn it on, and restart the iPhone."
        case .lookupFailed: "devicectl comes with Xcode. See the Xcode row."
        }
    }
}

public enum Devicectl {
    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    /// The tunnel states in which the iPhone can be reached over any transport.
    static let usableTunnelStates: Set<String> = ["connected", "connectable"]

    /// The devices of `devicectl list devices --json-output`.
    public static func parseDeviceList(_ data: Data) throws -> [CoreDevice] {
        let result = try resultObject(data)
        guard let devices = result["devices"] as? [[String: Any]] else {
            throw ParseError(description: "devicectl gave no device list")
        }
        return devices.compactMap(device)
    }

    /// The device of `devicectl device info details --json-output`.
    public static func parseDeviceDetails(_ data: Data) throws -> CoreDevice {
        guard let device = device(try resultObject(data)) else {
            throw ParseError(description: "devicectl gave no device details")
        }
        return device
    }

    private static func resultObject(_ data: Data) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError(description: "devicectl gave no JSON")
        }
        let outcome = (json["info"] as? [String: Any])?["outcome"] as? String
        guard outcome == "success", let result = json["result"] as? [String: Any] else {
            throw ParseError(description: "devicectl reported \(outcome ?? "no outcome")")
        }
        return result
    }

    /// Reads the fields that devicectl marks as deprecated, and falls back to their
    /// replacement in `properties`, which uses other names and shapes.
    static func device(_ d: [String: Any]) -> CoreDevice? {
        func dict(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
        let hardware = dict(d["hardwareProperties"]), deviceProps = dict(d["deviceProperties"])
        let connection = dict(d["connectionProperties"]), props = dict(d["properties"])
        let newHardware = dict(props?["hardware"]), newState = dict(props?["state"])
        let newConnection = dict(props?["connection"]), newSoftware = dict(props?["software"])

        guard let udid = hardware?["udid"] as? String ?? newHardware?["udid"] as? String,
              let name = deviceProps?["name"] as? String ?? newState?["name"] as? String
        else { return nil }
        let reality = hardware?["reality"] as? String ?? newHardware?["reality"] as? String
        // The new shape names the status by its only key: {"enabled": {"mode": 1}}.
        let newDeveloperMode = dict(newState?["developerModeStatus"]).flatMap { $0.count == 1 ? $0.keys.first : nil }
        return CoreDevice(
            udid: udid,
            name: name,
            isPhysical: reality == "physical",
            tunnelState: connection?["tunnelState"] as? String ?? newConnection?["state"] as? String,
            transportType: connection?["transportType"] as? String ?? newConnection?["transportType"] as? String,
            pairingState: connection?["pairingState"] as? String ?? newConnection?["pairingState"] as? String,
            developerModeStatus: deviceProps?["developerModeStatus"] as? String ?? newDeveloperMode,
            osVersion: deviceProps?["osVersionNumber"] as? String
                ?? dict(newSoftware?["osVersionNumber"])?["stringValue"] as? String,
            tunnelIPAddress: connection?["tunnelIPAddress"] as? String
                ?? newConnection?["tunnelIPAddressString"] as? String)
    }

    /// The CoreDevice of a capture device. The capture `uniqueID` is not the UDID and does not
    /// appear in the devicectl data, so the name is the only link, and it must match exactly.
    public static func match(captureName: String, in devices: [CoreDevice]) -> Result<CoreDevice, DeviceProblem> {
        let reachable = devices.filter { $0.isPhysical && $0.isReachable && $0.name == captureName }
        guard let device = reachable.first else { return .failure(.notPaired) }
        guard reachable.count == 1 else { return .failure(.duplicateName(captureName)) }
        guard device.developerModeStatus == "enabled" else { return .failure(.developerModeOff(captureName)) }
        return .success(device)
    }

    /// The WDA base URL for a tunnel address. The address is checked, because it goes into a URL.
    public static func wdaURL(tunnelAddress: String, port: Int = 8100) -> URL? {
        // A scoped address ("%en0") would need escaping in a URL. The tunnel address has no scope.
        guard !tunnelAddress.contains("%") else { return nil }
        if IPv6Address(tunnelAddress) != nil { return URL(string: "http://[\(tunnelAddress)]:\(port)") }
        if IPv4Address(tunnelAddress) != nil { return URL(string: "http://\(tunnelAddress):\(port)") }
        return nil
    }

    // MARK: - Running devicectl

    public static func listDevices() async throws -> [CoreDevice] {
        try parseDeviceList(try await run(["list", "devices"]))
    }

    public static func details(udid: String) async throws -> CoreDevice {
        try parseDeviceDetails(try await run(["device", "info", "details", "--device", udid]))
    }

    /// devicectl writes its JSON to a file. The file goes in this user's private temporary folder.
    private static func run(_ arguments: [String]) async throws -> Data {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("glasstap-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        // devicectl can hang on an iPhone that is still connecting. A quit waits for it, so it has a limit.
        let output = try await ChildProcess.run("/usr/bin/xcrun", ["devicectl"] + arguments + ["--json-output", file.path],
                                                keepLines: 5, timeout: .seconds(30))
        guard let data = try? Data(contentsOf: file) else {
            let detail = output.lines.last(where: { !$0.isEmpty }) ?? "exit status \(output.status)"
            throw ParseError(description: detail)
        }
        return data
    }
}
