import Foundation
import Network
import os
import Testing
@testable import GlasstapKit

/// A stand-in for WDA on a loopback port. It records each request and answers from a script.
final class FakeWDA: @unchecked Sendable {
    typealias Reply = (status: Int, json: String)
    let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-wda")
    private let log = OSAllocatedUnfairLock(initialState: [String]())
    private let reply: @Sendable (HTTPRequest) -> Reply

    init(port: UInt16, reply: @escaping @Sendable (HTTPRequest) -> Reply) throws {
        self.port = port
        self.reply = reply
        listener = try Listener.loopback(port: port)
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            Listener.readRequest(connection) { [self] request in
                let body = String(decoding: request.body, as: UTF8.self)
                log.withLock { $0.append("\(request.method) \(request.path)" + (body.isEmpty ? "" : " \(body)")) }
                let r = reply(request)
                Listener.respond(connection, HTTPResponse(status: r.status, headers: [("Content-Type", "application/json")],
                                                          body: Data(r.json.utf8)))
            }
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    var requests: [String] { log.withLock { $0 } }
    var url: URL { URL(string: "http://127.0.0.1:\(port)")! }
    func stop() { listener.cancel() }
}

@Suite(.serialized) struct WDAClientTests {
    let size = #"{"value":{"width":393,"height":852}}"#

    @Test func createsASessionWhenWDAHasNone() async throws {
        let wda = try FakeWDA(port: 39400) { [size] r in
            switch r.path {
            case "/status": (200, #"{"value":{},"sessionId":null}"#)
            case "/session": (200, #"{"value":{},"sessionId":"NEW"}"#)
            case "/session/NEW/window/size": (200, size)
            default: (200, #"{"value":null}"#)
            }
        }
        defer { wda.stop() }
        let client = WDAClient(baseURL: wda.url)
        try await client.perform(.home)
        try await client.perform(.switcher)
        #expect(wda.requests == [
            "GET /status",
            #"POST /session {"capabilities":{"alwaysMatch":{"platformName":"iOS"}}}"#,
            "GET /session/NEW/window/size",
            "POST /wda/homescreen {}",
            #"POST /session/NEW/wda/pressAndDragWithVelocity {"fromX":196.5,"fromY":851,"holdDuration":0.8,"pressDuration":0.05,"toX":196.5,"toY":520,"velocity":600}"#,
        ])
        #expect(try await client.windowSize() == ScreenSize(width: 393, height: 852))
    }

    @Test func aRejectedSessionIsReplacedOnce() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let wda = try FakeWDA(port: 39401) { [size] r in
            switch r.path {
            case "/status":
                let n = calls.withLock { $0 += 1; return $0 }
                return (200, #"{"value":{},"sessionId":"S\#(n)"}"#)
            case "/session/S1/actions": return (404, #"{"value":{"error":"invalid session id"}}"#)
            case "/session/S1/window/size", "/session/S2/window/size": return (200, size)
            default: return (200, #"{"value":null}"#)
            }
        }
        defer { wda.stop() }
        let client = WDAClient(baseURL: wda.url)
        try await client.perform(.tap(x: 10, y: 20, holdMS: 60))
        #expect(wda.requests.map { $0.split(separator: " ").prefix(2).joined(separator: " ") } == [
            "GET /status", "GET /session/S1/window/size", "POST /session/S1/actions",
            "GET /status", "GET /session/S2/window/size", "POST /session/S2/actions",
        ])
    }

    @Test func otherErrorsAreNotRetried() async throws {
        // WDA may have performed part of the action, so a second try could tap twice.
        let wda = try FakeWDA(port: 39402) { [size] r in
            switch r.path {
            case "/status": (200, #"{"value":{},"sessionId":"S"}"#)
            case "/session/S/window/size": (200, size)
            default: (500, #"{"value":{"error":"unknown error"}}"#)
            }
        }
        defer { wda.stop() }
        let client = WDAClient(baseURL: wda.url)
        await #expect(throws: WDAClient.WDAError.self) { try await client.perform(.type(text: "a")) }
        #expect(wda.requests.filter { $0.hasPrefix("POST /session/S/wda/keys") }.count == 1)
    }

    @Test func aSecondInvalidSessionIsReported() async throws {
        let wda = try FakeWDA(port: 39405) { [size] r in
            switch r.path {
            case "/status": (200, #"{"value":{},"sessionId":"S"}"#)
            case "/session/S/window/size": (200, size)
            default: (404, #"{"value":{"error":"invalid session id","message":"Session does not exist"}}"#)
            }
        }
        defer { wda.stop() }
        let client = WDAClient(baseURL: wda.url)
        await #expect(throws: WDAClient.WDAError.self) { try await client.perform(.tap(x: 1, y: 2, holdMS: 60)) }
        #expect(wda.requests.filter { $0.hasPrefix("POST /session/S/actions") }.count == 2)
    }

    @Test func screenshot() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let wda = try FakeWDA(port: 39403) { _ in (200, #"{"value":"\#(png.base64EncodedString())"}"#) }
        defer { wda.stop() }
        #expect(try await WDAClient(baseURL: wda.url).screenshot() == png)
        #expect(wda.requests == ["GET /screenshot"])
    }

    @Test func wakePressesHomeOnlyOnSpringBoard() async throws {
        let front = OSAllocatedUnfairLock(initialState: "com.apple.springboard")
        let wda = try FakeWDA(port: 39404) { [size] r in
            switch r.path {
            case "/status": (200, #"{"value":{},"sessionId":"S"}"#)
            case "/session/S/window/size": (200, size)
            case "/session/S/wda/activeAppInfo": (200, #"{"value":{"bundleId":"\#(front.withLock { $0 })"}}"#)
            default: (200, #"{"value":null}"#)
            }
        }
        defer { wda.stop() }
        let client = WDAClient(baseURL: wda.url)
        #expect(await client.wakeIfSpringBoardIsInFront())
        #expect(wda.requests.last == #"POST /session/S/wda/pressButton {"name":"home"}"#)
        front.withLock { $0 = "com.example.app" }
        let before = wda.requests.count
        #expect(!(await client.wakeIfSpringBoardIsInFront()))
        #expect(wda.requests.dropFirst(before) == ["GET /session/S/wda/activeAppInfo"])
    }

    @Test func unreachable() async {
        #expect(!(await WDAClient.isReachable(URL(string: "http://127.0.0.1:1")!)))
    }
}
