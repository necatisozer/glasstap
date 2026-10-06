import Foundation
import os
import Testing
@testable import GlasstapKit

/// The two listeners on real loopback sockets. WDA points at a closed port, so no iPhone is involved.
@Suite(.serialized) struct ServerTests {
    let token = AccessToken.generate()
    let controlPort: UInt16 = 39300
    let videoPort: UInt16 = 39301
    let session = URLSession(configuration: .ephemeral)

    func waitUntilReady(_ states: OSAllocatedUnfairLock<ListenerState>) async throws {
        for _ in 0..<100 where states.withLock({ $0 }) != .ready {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(states.withLock { $0 } == .ready)
    }

    func status(_ request: URLRequest) async throws -> (Int, Data) {
        let (data, response) = try await session.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, data)
    }

    @Test func controlServer() async throws {
        let state = OSAllocatedUnfairLock(initialState: ListenerState.stopped)
        let server = ControlServer(
            port: controlPort, videoPort: videoPort, token: token,
            wda: WDAClient(baseURL: URL(string: "http://127.0.0.1:1")!),
            pageTemplate: "<p>video on __VIDEO_PORT__</p>",
            onState: { s in state.withLock { $0 = s } })
        server.start()
        defer { server.stop() }
        try await waitUntilReady(state)
        let base = "http://127.0.0.1:\(controlPort)"

        let (pageStatus, page) = try await status(URLRequest(url: URL(string: base + "/")!))
        #expect(pageStatus == 200)
        #expect(String(decoding: page, as: UTF8.self) == "<p>video on \(videoPort)</p>")

        var tap = URLRequest(url: URL(string: base + "/tap")!)
        tap.httpMethod = "POST"
        tap.httpBody = Data(#"{"x":1,"y":2}"#.utf8)
        #expect(try await status(tap).0 == 403)

        tap.setValue(token.value, forHTTPHeaderField: "X-Glasstap")
        // The token passes. WDA is not there, so the action fails upstream.
        #expect(try await status(tap).0 == 502)

        tap.setValue("http://evil.example", forHTTPHeaderField: "Origin")
        #expect(try await status(tap).0 == 403)

        var unknown = URLRequest(url: URL(string: base + "/reboot")!)
        unknown.httpMethod = "POST"
        unknown.setValue(token.value, forHTTPHeaderField: "X-Glasstap")
        #expect(try await status(unknown).0 == 404)

        #expect(try await status(URLRequest(url: URL(string: base + "/info")!)).0 == 403)
        #expect(try await status(URLRequest(url: URL(string: base + "/screenshot?token=\(token.value)")!)).0 == 502)

        server.setVideoPort(40000)
        let (_, moved) = try await status(URLRequest(url: URL(string: base + "/")!))
        #expect(String(decoding: moved, as: UTF8.self) == "<p>video on 40000</p>")
    }

    @Test func videoServer() async throws {
        let state = OSAllocatedUnfairLock(initialState: ListenerState.stopped)
        let hub = ViewerHub()
        let server = VideoServer(port: videoPort, controlPort: controlPort, token: token, hub: hub,
                                 onState: { s in state.withLock { $0 = s } })
        server.start()
        defer { server.stop() }
        try await waitUntilReady(state)
        let base = "http://127.0.0.1:\(videoPort)"

        #expect(try await status(URLRequest(url: URL(string: base + "/video")!)).0 == 403)
        #expect(try await status(URLRequest(url: URL(string: base + "/other?token=\(token.value)")!)).0 == 404)
        var foreign = URLRequest(url: URL(string: base + "/video?token=\(token.value)")!)
        foreign.setValue("http://evil.example", forHTTPHeaderField: "Origin")
        #expect(try await status(foreign).0 == 403)

        var viewer = URLRequest(url: URL(string: base + "/video?token=\(token.value)")!)
        viewer.setValue("http://127.0.0.1:\(controlPort)", forHTTPHeaderField: "Origin")
        // URLSession holds the response back until it has 512 bytes of body, so send a frame first.
        let pending = Task { [session] in try await session.bytes(for: viewer) }
        for _ in 0..<100 where hub.viewerCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(hub.viewerCount == 1)
        #expect(hub.isWaitingForKeyFrame)
        let config = StreamConfig(codec: CodecString.hevc, width: 590, height: 1278)
        let frame = Data([0, 0, 0, 1, 0x40] + [UInt8](repeating: 7, count: 1000))
        hub.broadcast(StreamMessage.encode(.keyFrame, frame), key: true, config: config)
        let (bytes, response) = try await pending.value
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "http://127.0.0.1:\(controlPort)")
        var buffer = Data()
        var messages: [(type: UInt8, payload: Data)] = []
        for try await byte in bytes {
            buffer.append(byte)
            messages += StreamMessage.decode(&buffer)
            if messages.count == 2 { break }
        }
        #expect(messages.map(\.type) == [0, 1])
        #expect(messages[0].payload == config.json)
        #expect(messages[1].payload == frame)

        // A closed tab leaves at once, with no frame sent to notice it.
        session.invalidateAndCancel()
        for _ in 0..<100 where hub.viewerCount > 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(hub.viewerCount == 0)
    }
}
