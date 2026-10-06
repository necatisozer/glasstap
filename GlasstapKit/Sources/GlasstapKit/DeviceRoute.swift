import Foundation
import os

/// The iPhone that a request names. The paths carry it as `/devices/<id>/…`. A path without the
/// prefix is the form of older links, and it acts on the only iPhone.
public enum DevicePath: Equatable, Sendable {
    /// `/devices`
    case list
    /// `rest` starts with "/". `device` is nil for a path without the prefix.
    case route(device: String?, rest: String)

    static let prefix = "/devices/"

    /// nil for a malformed prefix, such as `/devices/<id>` with nothing after the id.
    public static func parse(_ path: String) -> DevicePath? {
        if path == "/devices" { return .list }
        guard path.hasPrefix(prefix) else { return .route(device: nil, rest: path) }
        let tail = path.dropFirst(prefix.count)
        guard let slash = tail.firstIndex(of: "/"),
              let id = String(tail[..<slash]).removingPercentEncoding, !id.isEmpty
        else { return nil }
        return .route(device: id, rest: String(tail[slash...]))
    }
}

/// Why a request does not reach an iPhone.
public enum RouteError: Error, Equatable, Sendable {
    case unknownDevice(String)
    /// A path without the prefix, and no iPhone is connected.
    case noDevice
    /// A path without the prefix, and this many iPhones are connected.
    case ambiguous(Int)

    public var status: Int {
        switch self {
        case .unknownDevice: 404
        case .noDevice, .ambiguous: 409
        }
    }

    public var message: String {
        switch self {
        case let .unknownDevice(id): "No iPhone with the id \(id) is connected."
        case .noDevice: "No iPhone is connected."
        case let .ambiguous(count): "\(count) iPhones are connected. Name one: /devices/<udid>/… (GET /devices lists them)."
        }
    }
}

/// Something that the paths can name: by its UDID, or by its capture id until the UDID is known.
public protocol DeviceKeyed {
    /// The capture `uniqueID`, known from the start.
    var captureID: String { get }
    var udid: String? { get }
}

extension DeviceKeyed {
    /// The id in the paths and in the viewer link.
    public var key: String { udid ?? captureID }
}

public enum DeviceRouting {
    /// The item that `id` names. With no id, the only item. The UDID wins over the capture id,
    /// but a page that learned the capture id before devicectl named the iPhone still reaches it.
    public static func select<T: DeviceKeyed>(_ id: String?, in items: [T]) -> Result<T, RouteError> {
        guard let id else {
            switch items.count {
            case 0: return .failure(.noDevice)
            case 1: return .success(items[0])
            default: return .failure(.ambiguous(items.count))
            }
        }
        if let item = items.first(where: { $0.udid == id }) ?? items.first(where: { $0.captureID == id }) {
            return .success(item)
        }
        return .failure(.unknownDevice(id))
    }
}

/// What the listeners need of one iPhone.
public struct DeviceRoute: DeviceKeyed, Sendable {
    public var captureID: String
    public var udid: String?
    public var name: String
    /// One word for the capture, such as "running".
    public var state: String
    /// One word for WDA, such as "running".
    public var wda: String
    public var hub: ViewerHub
    public var client: WDAClient

    public init(captureID: String, udid: String?, name: String, state: String, wda: String,
                hub: ViewerHub, client: WDAClient) {
        self.captureID = captureID
        self.udid = udid
        self.name = name
        self.state = state
        self.wda = wda
        self.hub = hub
        self.client = client
    }
}

/// One entry of `GET /devices`. `udid` is the id for the paths: the capture id until devicectl names
/// the iPhone. `captureID` stays the same, so a page that holds it finds the iPhone after the UDID is known.
public struct DeviceListing: Codable, Equatable, Sendable {
    public var udid: String
    public var captureID: String
    public var name: String
    public var state: String
    public var wda: String
}

/// The iPhones as the listeners see them. The app owns the sessions on the main actor, and the
/// listeners run on their own queues, so the app copies what they need in here after each change.
public final class DeviceDirectory: Sendable {
    private let routes = OSAllocatedUnfairLock<[DeviceRoute]>(initialState: [])

    public init(_ routes: [DeviceRoute] = []) {
        set(routes)
    }

    public func set(_ new: [DeviceRoute]) {
        routes.withLock { $0 = new }
    }

    public var all: [DeviceRoute] { routes.withLock { $0 } }

    public func route(_ id: String?) -> Result<DeviceRoute, RouteError> {
        DeviceRouting.select(id, in: all)
    }

    public var listing: [DeviceListing] {
        all.map { DeviceListing(udid: $0.key, captureID: $0.captureID, name: $0.name, state: $0.state, wda: $0.wda) }
    }

    /// Closes the viewers of every iPhone, for a restart of the video listener.
    func leaveAll() {
        for route in all { route.hub.leaveAll() }
    }
}

/// The sessions of the connected iPhones, in the order of the capture devices. The key of a
/// session is its UDID once devicectl names the iPhone, and its capture id until then.
public struct DeviceRegistry<Session> {
    public struct Entry: DeviceKeyed {
        public let captureID: String
        public fileprivate(set) var name: String
        public fileprivate(set) var udid: String?
        public let session: Session

        public var screen: ScreenDevice { ScreenDevice(id: captureID, name: name) }
    }

    public struct Changes {
        public var added: [Session] = []
        public var removed: [Session] = []
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    public var sessions: [Session] { entries.map(\.session) }

    /// Follows the capture devices: a new device gets a session from `make`, and a device that
    /// went loses its session. A device keeps its session, and its UDID, across a change of name.
    public mutating func sync(_ devices: [ScreenDevice], make: (ScreenDevice) -> Session) -> Changes {
        var changes = Changes()
        let present = Set(devices.map(\.id))
        changes.removed = entries.filter { !present.contains($0.captureID) }.map(\.session)
        let old = Dictionary(entries.map { ($0.captureID, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        entries = devices.compactMap { device in
            // A capture id appears once. A repeat would give one iPhone two sessions.
            guard seen.insert(device.id).inserted else { return nil }
            if var entry = old[device.id] {
                entry.name = device.name
                return entry
            }
            let session = make(device)
            changes.added.append(session)
            return Entry(captureID: device.id, name: device.name, udid: nil, session: session)
        }
        return changes
    }

    /// True if another capture device has the same name. Then the name cannot tell the two apart.
    public func sharesName(_ captureID: String) -> Bool {
        guard let name = entry(captureID: captureID)?.name else { return false }
        return entries.filter { $0.name == name }.count > 1
    }

    /// Records the UDID of a capture device. Returns false, and changes nothing, if another session
    /// holds it: two WDA test runs on one iPhone conflict. The UDID stays when a later lookup fails,
    /// so that a viewer link with the UDID keeps working while devicectl recovers.
    @discardableResult
    public mutating func adopt(udid: String, for captureID: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.captureID == captureID }) else { return false }
        if entries.contains(where: { $0.captureID != captureID && $0.udid == udid }) { return false }
        entries[index].udid = udid
        return true
    }

    public func entry(captureID: String) -> Entry? {
        entries.first { $0.captureID == captureID }
    }

    public func select(_ id: String?) -> Result<Entry, RouteError> {
        DeviceRouting.select(id, in: entries)
    }
}

extension DeviceRegistry: Sendable where Session: Sendable {}
extension DeviceRegistry.Entry: Sendable where Session: Sendable {}
extension DeviceRegistry.Changes: Sendable where Session: Sendable {}

extension WDAState {
    /// One word, for `GET /devices`.
    public var word: String {
        switch self {
        case .notConfigured: "not-configured"
        case .downloading: "downloading"
        case .building: "building"
        case .starting: "starting"
        case .running: "running"
        case .restarting: "restarting"
        case .failed: "failed"
        }
    }
}
