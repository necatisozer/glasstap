import Foundation
import Testing
@testable import GlasstapKit

@Suite struct ControlActionTests {
    let size = ScreenSize(width: 393, height: 852)

    func parse(_ kind: String, _ json: String = "") throws -> ControlAction {
        try ControlAction.parse(kind: kind, body: Data(json.utf8))
    }

    func body(_ r: WDARequest) throws -> [String: Any] {
        let data = try #require(r.body)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func parsesTheActionSet() throws {
        #expect(try parse("tap", #"{"x":10.4,"y":20.6}"#) == .tap(x: 10.4, y: 20.6, holdMS: 60))
        #expect(try parse("tap", #"{"x":1,"y":2,"hold":900.7}"#) == .tap(x: 1, y: 2, holdMS: 900))
        #expect(try parse("swipe", #"{"x1":1,"y1":2,"x2":3,"y2":4}"#) == .swipe(x1: 1, y1: 2, x2: 3, y2: 4, durationMS: 250))
        #expect(try parse("switcher") == .switcher)
        #expect(try parse("wake", "{}") == .wake)
        #expect(try parse("home") == .home)
        #expect(try parse("type", #"{"text":"hi"}"#) == .type(text: "hi"))
    }

    @Test func rejectsUnknownActionsAndBadBodies() {
        #expect(throws: ControlAction.ParseError.unknownAction) { try parse("screenshot") }
        #expect(throws: ControlAction.ParseError.unknownAction) { try parse("") }
        #expect(throws: ControlAction.ParseError.badBody) { try parse("tap", #"{"x":1}"#) }
        #expect(throws: ControlAction.ParseError.badBody) { try parse("tap", #"{"x":"1","y":2}"#) }
        #expect(throws: ControlAction.ParseError.badBody) { try parse("tap", #"{"x":true,"y":2}"#) }
        #expect(throws: ControlAction.ParseError.badBody) { try parse("tap", #"{"x":1e300,"y":2}"#) }
        #expect(throws: ControlAction.ParseError.badBody) { try parse("type", "{}") }
        #expect(throws: ControlAction.ParseError.badBody) { try parse("home", "[]") }
        #expect(throws: ControlAction.ParseError.badBody) { try parse("home", "not json") }
    }

    @Test func tapIsAW3CPointerAction() throws {
        let r = ControlAction.tap(x: 10.5, y: 20.6, holdMS: 60).wdaRequest(sessionID: "S", size: size)
        #expect(r.method == "POST")
        #expect(r.path == "/session/S/actions")
        let actions = try #require(try body(r)["actions"] as? [[String: Any]])
        #expect(actions[0]["id"] as? String == "finger1")
        #expect((actions[0]["parameters"] as? [String: String]) == ["pointerType": "touch"])
        let moves = try #require(actions[0]["actions"] as? [[String: Any]])
        #expect(moves.map { $0["type"] as? String } == ["pointerMove", "pointerDown", "pause", "pointerUp"])
        #expect(moves[0]["x"] as? Int == 10)
        #expect(moves[0]["y"] as? Int == 21)
        #expect(moves[2]["duration"] as? Int == 60)
    }

    @Test func swipe() throws {
        let r = ControlAction.swipe(x1: 6, y1: 426, x2: 275.1, y2: 426, durationMS: 250).wdaRequest(sessionID: "S", size: size)
        let actions = try #require(try body(r)["actions"] as? [[String: Any]])
        let moves = try #require(actions[0]["actions"] as? [[String: Any]])
        #expect(moves.map { $0["type"] as? String } == ["pointerMove", "pointerDown", "pause", "pointerMove", "pointerUp"])
        #expect(moves[2]["duration"] as? Int == 30)
        #expect(moves[3]["duration"] as? Int == 250)
        #expect(moves[3]["x"] as? Int == 275)
    }

    @Test func switcherIsTheTestedEdgeGesture() throws {
        let r = ControlAction.switcher.wdaRequest(sessionID: "S", size: size)
        #expect(r.path == "/session/S/wda/pressAndDragWithVelocity")
        let b = try body(r)
        #expect(b["fromX"] as? Double == 196.5)
        #expect(b["fromY"] as? Double == 851)
        #expect(b["toX"] as? Double == 196.5)
        #expect(b["toY"] as? Int == 520)
        #expect(b["pressDuration"] as? Double == 0.05)
        #expect(b["holdDuration"] as? Double == 0.8)
        let json = String(decoding: try #require(r.body), as: UTF8.self)
        #expect(json.contains(#""pressDuration":0.05,"#))
        #expect(json.contains(#""holdDuration":0.8,"#))
        #expect(b["velocity"] as? Int == 600)
    }

    @Test func buttonsAndKeys() throws {
        #expect(ControlAction.home.wdaRequest(sessionID: "S", size: size).path == "/wda/homescreen")
        #expect(ControlAction.wake.wdaRequest(sessionID: "S", size: size).path == "/wda/unlock")
        let keys = ControlAction.type(text: "a\né").wdaRequest(sessionID: "S", size: size)
        #expect(keys.path == "/session/S/wda/keys")
        #expect(try body(keys)["value"] as? [String] == ["a", "\n", "é"])
    }
}
