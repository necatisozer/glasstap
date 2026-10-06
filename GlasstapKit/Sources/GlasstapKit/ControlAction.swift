import Foundation

/// The window size of the iPhone in points, as WDA reports it.
public struct ScreenSize: Sendable, Equatable, Codable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// One request to WDA.
public struct WDARequest: Sendable, Equatable {
    public let method: String
    public let path: String
    public let body: Data?

    init(_ method: String, _ path: String, _ body: [String: Any]? = nil) {
        self.method = method
        self.path = path
        self.body = body.map { try! JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
    }

    static let status = WDARequest("GET", "/status")
    static let createSession = WDARequest("POST", "/session", ["capabilities": ["alwaysMatch": ["platformName": "iOS"]]])
    static let screenshot = WDARequest("GET", "/screenshot")
    static func windowSize(_ sid: String) -> WDARequest { WDARequest("GET", "/session/\(sid)/window/size") }
    static func activeAppInfo(_ sid: String) -> WDARequest { WDARequest("GET", "/session/\(sid)/wda/activeAppInfo") }
    static func pressHome(_ sid: String) -> WDARequest { WDARequest("POST", "/session/\(sid)/wda/pressButton", ["name": "home"]) }
}

/// The fixed set of actions that the viewer may ask for. The browser never reaches WDA itself.
public enum ControlAction: Sendable, Equatable {
    case tap(x: Double, y: Double, holdMS: Int)
    case swipe(x1: Double, y1: Double, x2: Double, y2: Double, durationMS: Int)
    case switcher
    case wake
    case home
    case type(text: String)

    public enum ParseError: Error, Equatable {
        case unknownAction
        case badBody
    }

    /// Parses `POST /<kind>` with its JSON body.
    public static func parse(kind: String, body: Data) throws(ParseError) -> ControlAction {
        let known = ["tap", "swipe", "switcher", "wake", "home", "type"]
        guard known.contains(kind) else { throw .unknownAction }
        let json: [String: Any]
        if body.isEmpty {
            json = [:]
        } else {
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw .badBody }
            json = object
        }
        func number(_ key: String, _ fallback: Double? = nil) throws(ParseError) -> Double {
            // Bounded, so that the conversion to Int below cannot trap.
            if let n = json[key] as? NSNumber, !(n === kCFBooleanTrue || n === kCFBooleanFalse),
               n.doubleValue.isFinite, abs(n.doubleValue) < 1e9 { return n.doubleValue }
            if json[key] == nil, let fallback { return fallback }
            throw .badBody
        }
        switch kind {
        case "tap":
            return .tap(x: try number("x"), y: try number("y"), holdMS: Int(try number("hold", 60)))
        case "swipe":
            return .swipe(x1: try number("x1"), y1: try number("y1"), x2: try number("x2"), y2: try number("y2"),
                          durationMS: Int(try number("ms", 250)))
        case "switcher": return .switcher
        case "wake": return .wake
        case "home": return .home
        default:
            guard let text = json["text"] as? String else { throw .badBody }
            return .type(text: text)
        }
    }

    /// The WDA call for this action, in the session `sid` of a screen of `size` points.
    public func wdaRequest(sessionID sid: String, size: ScreenSize) -> WDARequest {
        switch self {
        case let .tap(x, y, hold):
            return WDARequest("POST", "/session/\(sid)/actions", Self.pointer([
                ["type": "pointerMove", "duration": 0, "x": Self.round(x), "y": Self.round(y)],
                ["type": "pointerDown", "button": 0],
                ["type": "pause", "duration": hold],
                ["type": "pointerUp", "button": 0],
            ]))
        case let .swipe(x1, y1, x2, y2, ms):
            return WDARequest("POST", "/session/\(sid)/actions", Self.pointer([
                ["type": "pointerMove", "duration": 0, "x": Self.round(x1), "y": Self.round(y1)],
                ["type": "pointerDown", "button": 0],
                ["type": "pause", "duration": 30],
                ["type": "pointerMove", "duration": ms, "x": Self.round(x2), "y": Self.round(y2)],
                ["type": "pointerUp", "button": 0],
            ]))
        case .switcher:
            // A swipe made of W3C pointer actions does not start the system gesture.
            // One XCTest press, drag and hold from the bottom edge does (tested).
            let w = size.width, h = size.height
            return WDARequest("POST", "/session/\(sid)/wda/pressAndDragWithVelocity", [
                "fromX": w / 2, "fromY": h - 1, "toX": w / 2, "toY": Self.round(h * 0.61),
                // Decimal, so that the JSON says 0.05 and not 0.050000000000000003.
                "pressDuration": Decimal(string: "0.05")!, "holdDuration": Decimal(string: "0.8")!, "velocity": 600,
            ])
        case .wake:
            return WDARequest("POST", "/wda/unlock", [:])
        case .home:
            return WDARequest("POST", "/wda/homescreen", [:])
        case let .type(text):
            // One key per code point, as WDA expects a list of strings.
            return WDARequest("POST", "/session/\(sid)/wda/keys", ["value": text.unicodeScalars.map { String($0) }])
        }
    }

    private static func pointer(_ moves: [[String: Any]]) -> [String: Any] {
        ["actions": [["type": "pointer", "id": "finger1", "parameters": ["pointerType": "touch"], "actions": moves]]]
    }

    /// WDA takes whole points. Half rounds to even.
    private static func round(_ v: Double) -> Int { Int(v.rounded(.toNearestOrEven)) }
}
