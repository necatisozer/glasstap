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

/// What the listeners need of one iPhone. Its session owns it and updates it on its own changes.
/// The listeners read it on their own queues, so a lock guards the parts that change.
public final class DeviceRoute: Sendable {
    /// The parts that change, as `GET /devices` lists them.
    public struct Info: Equatable, Sendable, Encodable {
        public let captureID: String
        public var udid: String?
        public var name: String
        /// One word for the capture, such as "running".
        public var state: String
        /// One word for WDA, such as "running".
        public var wda: String

        /// The id in the paths and in the viewer link: the UDID once devicectl names the iPhone,
        /// and the capture id until then.
        public var key: String { udid ?? captureID }

        private enum CodingKeys: String, CodingKey { case udid, captureID, name, state, wda }

        /// `udid` is the key, so that a page always has an id for the paths.
        public func encode(to encoder: any Swift.Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(key, forKey: .udid)
            try c.encode(captureID, forKey: .captureID)
            try c.encode(name, forKey: .name)
            try c.encode(state, forKey: .state)
            try c.encode(wda, forKey: .wda)
        }
    }

    public let captureID: String
    public let hub: ViewerHub
    public let client: WDAClient
    private let info: OSAllocatedUnfairLock<Info>

    public init(captureID: String, name: String, hub: ViewerHub, client: WDAClient, udid: String? = nil,
                state: String = "idle", wda: String = WDAState.notConfigured.word) {
        self.captureID = captureID
        self.hub = hub
        self.client = client
        info = OSAllocatedUnfairLock(initialState: Info(captureID: captureID, udid: udid, name: name, state: state, wda: wda))
    }

    public var current: Info { info.withLock { $0 } }
    public var udid: String? { current.udid }
    public var key: String { current.key }

    func setUDID(_ udid: String) { info.withLock { $0.udid = udid } }
    func setName(_ name: String) { info.withLock { $0.name = name } }
    func setState(_ state: String) { info.withLock { $0.state = state } }
    func setWDA(_ wda: String) { info.withLock { $0.wda = wda } }
}

public enum DeviceRouting {
    /// The route that `id` names. With no id, the only route. The UDID wins over the capture id,
    /// but a page that learned the capture id before devicectl named the iPhone still reaches it.
    public static func select(_ id: String?, in routes: [DeviceRoute]) -> Result<DeviceRoute, RouteError> {
        guard let id else {
            switch routes.count {
            case 0: return .failure(.noDevice)
            case 1: return .success(routes[0])
            default: return .failure(.ambiguous(routes.count))
            }
        }
        if let route = routes.first(where: { $0.udid == id }) ?? routes.first(where: { $0.captureID == id }) {
            return .success(route)
        }
        return .failure(.unknownDevice(id))
    }
}

/// The iPhones as the listeners see them. The app sets the routes when an iPhone comes or goes.
/// Each route changes by itself, through its session.
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

    /// The body of `GET /devices`.
    public var listing: [DeviceRoute.Info] { all.map(\.current) }

    /// Closes the viewers of every iPhone, for a restart of the video listener.
    func leaveAll() {
        for route in all { route.hub.leaveAll() }
    }
}

/// A session that the registry keeps: it owns the route of its iPhone.
public protocol RoutedSession: AnyObject {
    var route: DeviceRoute { get }
}

/// The sessions of the connected iPhones, in the order of the capture devices.
public struct DeviceRegistry<Session: RoutedSession> {
    public struct Changes {
        public var added: [Session] = []
        public var removed: [Session] = []
    }

    public private(set) var sessions: [Session] = []
    /// The capture devices of the last `sync`.
    public private(set) var screens: [ScreenDevice] = []

    public init() {}

    public var routes: [DeviceRoute] { sessions.map(\.route) }

    /// Follows the capture devices: a new device gets a session from `make`, and a device that
    /// went loses its session. A device keeps its session, and its UDID, across a change of name.
    public mutating func sync(_ devices: [ScreenDevice], make: (ScreenDevice) -> Session) -> Changes {
        var changes = Changes()
        var seen = Set<String>()
        // A capture id appears once. A repeat would give one iPhone two sessions.
        screens = devices.filter { seen.insert($0.id).inserted }
        let present = Set(screens.map(\.id))
        changes.removed = sessions.filter { !present.contains($0.route.captureID) }
        let old = Dictionary(sessions.map { ($0.route.captureID, $0) }, uniquingKeysWith: { first, _ in first })
        sessions = screens.map { device in
            if let session = old[device.id] { return session }
            let session = make(device)
            changes.added.append(session)
            return session
        }
        return changes
    }

    /// True if another capture device has the same name. Then the name cannot tell the two apart.
    public func sharesName(_ captureID: String) -> Bool {
        guard let name = screens.first(where: { $0.id == captureID })?.name else { return false }
        return screens.filter { $0.name == name }.count > 1
    }

    /// Records the UDID of a capture device. Returns false, and changes nothing, if another session
    /// holds it: two WDA test runs on one iPhone conflict. The UDID stays when a later lookup fails,
    /// so that a viewer link with the UDID keeps working while devicectl recovers.
    @discardableResult
    public func adopt(udid: String, for captureID: String) -> Bool {
        guard let session = session(captureID: captureID) else { return false }
        if sessions.contains(where: { $0 !== session && $0.route.udid == udid }) { return false }
        session.route.setUDID(udid)
        return true
    }

    public func session(captureID: String) -> Session? {
        sessions.first { $0.route.captureID == captureID }
    }
}

extension DeviceRegistry: Sendable where Session: Sendable {}
extension DeviceRegistry.Changes: Sendable where Session: Sendable {}

extension WDAState {
    /// One word, for `GET /devices`.
    public var word: String {
        switch self {
        case .notConfigured: "not-configured"
        case .downloading: "downloading"
        case .building: "building"
        case .starting: "starting"
        case .waitingForUnlock: "waiting-for-unlock"
        case .running: "running"
        case .restarting: "restarting"
        case .failed: "failed"
        }
    }
}
