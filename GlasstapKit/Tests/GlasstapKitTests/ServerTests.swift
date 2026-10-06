import Foundation
import Network
import os
import Testing
@testable import GlasstapKit

extension DeviceDirectory {
    /// One iPhone whose WDA is at a closed port, so no iPhone is involved.
    static func single(hub: ViewerHub = ViewerHub(), captureID: String = "capture-1", udid: String? = "UDID-1",
                       name: String = "Phone") -> DeviceDirectory {
        DeviceDirectory([.fake(captureID: captureID, udid: udid, name: name, hub: hub)])
    }
}

extension DeviceRoute {
    static func fake(captureID: String, udid: String?, name: String, hub: ViewerHub = ViewerHub()) -> DeviceRoute {
        DeviceRoute(captureID: captureID, name: name, hub: hub, client: WDAClient(baseURL: URL(string: "http://127.0.0.1:1")!),
                    udid: udid, state: "running", wda: "running")
    }
}

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
            port: controlPort, videoPort: videoPort, token: token, devices: .single(),
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
        #expect(try await status(URLRequest(url: URL(string: base + "/locked")!)).0 == 403)
        // The fake WDA runs at a closed port, so the lock state fails upstream.
        #expect(try await status(URLRequest(url: URL(string: base + "/locked?token=\(token.value)")!)).0 == 502)
    }

    @Test func lockStateWithoutWDA() async throws {
        let waiting = DeviceRoute.fake(captureID: "c1", udid: "U1", name: "Locked")
        waiting.setWDA(WDAState.waitingForUnlock.word)
        let off = DeviceRoute.fake(captureID: "c2", udid: "U2", name: "Off")
        off.setWDA(WDAState.notConfigured.word)
        let state = OSAllocatedUnfairLock(initialState: ListenerState.stopped)
        let server = ControlServer(port: controlPort, videoPort: videoPort, token: token,
                                   devices: DeviceDirectory([waiting, off]), pageTemplate: "",
                                   onState: { s in state.withLock { $0 = s } })
        server.start()
        defer { server.stop() }
        try await waitUntilReady(state)
        func lock(_ id: String) async throws -> String {
            let url = URL(string: "http://127.0.0.1:\(controlPort)/devices/\(id)/locked?token=\(token.value)")!
            let (code, body) = try await status(URLRequest(url: url))
            #expect(code == 200)
            return String(decoding: body, as: UTF8.self)
        }
        // A WDA start that waits for the unlock: locked, and only the user at the iPhone can unlock it.
        #expect(try await lock("U1") == #"{"canWake":false,"locked":true}"#)
        #expect(try await lock("U2") == #"{"canWake":false,"locked":false}"#)
    }

    @Test func videoServer() async throws {
        let state = OSAllocatedUnfairLock(initialState: ListenerState.stopped)
        let hub = ViewerHub()
        let server = VideoServer(port: videoPort, controlPort: controlPort, token: token, devices: .single(hub: hub),
                                 onState: { s in state.withLock { $0 = s } })
        server.start()
        defer { server.stop() }
        try await waitUntilReady(state)
        let base = "http://127.0.0.1:\(videoPort)"
        // A viewer that does not ask for stats gets none, because older pages would decode them as frames.
        hub.setStats(StreamStats(bitrate: 620_000, fps: 30))

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
        // The config names this stream's session, for the viewer's reports.
        let sent = try JSONDecoder().decode(StreamConfig.self, from: messages[0].payload)
        #expect(sent.codec == config.codec && sent.width == config.width && sent.height == config.height)
        #expect(sent.session?.count == 32)
        #expect(messages[1].payload == frame)

        // A closed tab leaves at once, with no frame sent to notice it.
        session.invalidateAndCancel()
        for _ in 0..<100 where hub.viewerCount > 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(hub.viewerCount == 0)
    }

    @Test func statsGoToAViewerThatAsks() async throws {
        let state = OSAllocatedUnfairLock(initialState: ListenerState.stopped)
        let hub = ViewerHub()
        // A port of its own: the listener of the test before may still be closing.
        let videoPort: UInt16 = 39302
        let server = VideoServer(port: videoPort, controlPort: controlPort, token: token, devices: .single(hub: hub),
                                 onState: { s in state.withLock { $0 = s } })
        server.start()
        defer { server.stop() }
        try await waitUntilReady(state)
        let stats = StreamStats(bitrate: 620_000, fps: 15)
        hub.setStats(stats)

        let url = URL(string: "http://127.0.0.1:\(videoPort)/video?token=\(token.value)&stats=1")!
        let pending = Task { [session] in try await session.bytes(for: URLRequest(url: url)) }
        for _ in 0..<100 where hub.viewerCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(hub.viewerCount == 1)
        let config = StreamConfig(codec: CodecString.hevc, width: 590, height: 1278)
        let frame = Data([0, 0, 0, 1, 0x40] + [UInt8](repeating: 7, count: 1000))
        hub.broadcast(StreamMessage.encode(.keyFrame, frame), key: true, config: config)
        let (bytes, _) = try await pending.value
        var buffer = Data()
        var messages: [(type: UInt8, payload: Data)] = []
        for try await byte in bytes {
            buffer.append(byte)
            messages += StreamMessage.decode(&buffer)
            if messages.count == 3 { break }
        }
        // The current target comes at once, before the first picture.
        #expect(messages.map(\.type) == [4, 0, 1])
        #expect(try JSONDecoder().decode(StreamStats.self, from: messages[0].payload) == stats)
        // The stats message counts in the backlog like a frame, and leaves it when sent.
        for _ in 0..<100 where (hub.takeLinkSample()?.backlog ?? 0) > 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(hub.takeLinkSample()?.backlog == 0)
        session.invalidateAndCancel()
    }
}

/// The stats that a viewer sees when it joins, and after the capture stops.
@Suite(.serialized) struct StatsResetTests {
    let token = AccessToken.generate()
    let session = URLSession(configuration: .ephemeral)

    /// Opens a stats viewer and returns the first `count` messages, after a key frame from the hub.
    func firstMessages(_ count: Int, port: UInt16, hub: ViewerHub, during: () -> Void = {}) async throws -> [(type: UInt8, payload: Data)] {
        let state = OSAllocatedUnfairLock(initialState: ListenerState.stopped)
        let server = VideoServer(port: port, controlPort: port - 1, token: token, devices: .single(hub: hub),
                                 onState: { s in state.withLock { $0 = s } })
        server.start()
        defer { server.stop() }
        for _ in 0..<100 where state.withLock({ $0 }) != .ready { try await Task.sleep(for: .milliseconds(20)) }
        let url = URL(string: "http://127.0.0.1:\(port)/video?token=\(token.value)&stats=1")!
        let pending = Task { [session] in try await session.bytes(for: URLRequest(url: url)) }
        for _ in 0..<100 where hub.viewerCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        during()
        let config = StreamConfig(codec: CodecString.hevc, width: 590, height: 1278)
        hub.broadcast(StreamMessage.encode(.keyFrame, Data(count: 1000)), key: true, config: config)
        let (bytes, _) = try await pending.value
        var buffer = Data()
        var messages: [(type: UInt8, payload: Data)] = []
        for try await byte in bytes {
            buffer.append(byte)
            messages += StreamMessage.decode(&buffer)
            if messages.count == count { break }
        }
        session.invalidateAndCancel()
        return messages
    }

    func stats(_ m: (type: UInt8, payload: Data)) throws -> StreamStats? {
        m.type == StreamMessageType.stats.rawValue ? try JSONDecoder().decode(StreamStats.self, from: m.payload) : nil
    }

    @Test func aNewViewerStartsFromTheSettings() async throws {
        let hub = ViewerHub()
        // As the capture engine does: it resets the target for the new viewer before the viewer gets stats.
        hub.setJoinHandler { hub.setStats(StreamStats(bitrate: 800_000, fps: 30)) }
        // The viewer before lowered the target.
        hub.setStats(StreamStats(bitrate: 300_000, fps: 30))
        let messages = try await firstMessages(3, port: 39305, hub: hub)
        #expect(try messages.compactMap(stats) == [StreamStats(bitrate: 800_000, fps: 30)])
    }

    @Test func aViewerGetsEachNewValueOnce() async throws {
        let hub = ViewerHub()
        hub.setStats(StreamStats(bitrate: 800_000, fps: 30))
        let messages = try await firstMessages(5, port: 39307, hub: hub) {
            hub.setStats(StreamStats(bitrate: 300_000, fps: 30))
            // The same value again is not sent twice.
            hub.setStats(StreamStats(bitrate: 300_000, fps: 30))
            // The capture stops: the engine sets the settings again.
            hub.setStats(StreamStats(bitrate: 800_000, fps: 30))
        }
        #expect(try messages.compactMap(stats) == [
            StreamStats(bitrate: 800_000, fps: 30), StreamStats(bitrate: 300_000, fps: 30), StreamStats(bitrate: 800_000, fps: 30),
        ])
    }
}

/// The control listener keeps a connection open between requests, so that the viewer's reports
/// do not each pay for a new connection, which through `ssh -L` is a new SSH channel.
@Suite struct KeepAliveTests {
    @Test func requestsShareOneConnectionUntilTheClientCloses() async throws {
        let token = AccessToken.generate()
        let state = OSAllocatedUnfairLock(initialState: ListenerState.stopped)
        let server = ControlServer(port: 39309, videoPort: 39308, token: token, devices: .single(),
                                   pageTemplate: nil, onState: { s in state.withLock { $0 = s } })
        server.start()
        defer { server.stop() }
        for _ in 0..<100 where state.withLock({ $0 }) != .ready { try await Task.sleep(for: .milliseconds(20)) }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(39309).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(connected == 0)

        /// Sends one report for an unknown session and reads the whole answer.
        func ask(_ extraHeader: String = "") -> String {
            let body = #"{"session":"none","received":0}"#
            let request = "POST /stats HTTP/1.1\r\nHost: 127.0.0.1:39309\r\nX-Glasstap: \(token.value)\r\n\(extraHeader)"
                + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
            _ = request.withCString { send(fd, $0, strlen($0), 0) }
            var answer = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            // The answer is short: its header and the body "unknown session".
            while !String(decoding: answer, as: UTF8.self).hasSuffix("unknown session") {
                let n = recv(fd, &buffer, buffer.count, 0)
                if n <= 0 { break }
                answer.append(contentsOf: buffer[0..<n])
            }
            return String(decoding: answer, as: UTF8.self)
        }

        for _ in 0..<2 {
            let answer = ask()
            #expect(answer.hasPrefix("HTTP/1.1 404"))
            #expect(answer.contains("Connection: keep-alive\r\n"))
        }
        let last = ask("Connection: close\r\n")
        #expect(last.hasPrefix("HTTP/1.1 404"))
        #expect(last.contains("Connection: close\r\n"))
        var buffer = [UInt8](repeating: 0, count: 16)
        #expect(recv(fd, &buffer, buffer.count, 0) == 0)
    }
}

/// `POST /stats`: the viewer's report of the bytes it has received.
@Suite struct StatsReportTests {
    let token = AccessToken.generate()
    let hub = ViewerHub()

    var server: ControlServer {
        ControlServer(port: 39330, videoPort: 39331, token: token, devices: .single(hub: hub),
                      pageTemplate: nil, onState: { _ in })
    }

    func post(_ body: String, token: String?, origin: String? = nil) async -> Int {
        var headers = [(name: "Host", value: "127.0.0.1:39330")]
        if let token { headers.append(("X-Glasstap", token)) }
        if let origin { headers.append(("Origin", origin)) }
        let request = HTTPRequest(method: "POST", target: "/stats", headers: headers, body: Data(body.utf8))
        return await server.response(to: request).status
    }

    @Test func aReportForTheCurrentSessionCounts() async {
        let session = hub.join(NWConnection(host: "127.0.0.1", port: 9, using: .tcp))!
        #expect(hub.takeLinkSample()?.feedback == nil)
        #expect(await post(#"{"session":"\#(session)","received":0}"#, token: token.value) == 200)
        #expect(hub.takeLinkSample()?.feedback == ViewerFeedback(queue: 0, growth: 0, keyFrame: 0))
    }

    @Test func aWrongTokenOrSessionChangesNothing() async {
        let session = hub.join(NWConnection(host: "127.0.0.1", port: 9, using: .tcp))!
        let body = #"{"session":"\#(session)","received":0}"#
        #expect(await post(body, token: nil) == 403)
        #expect(await post(body, token: AccessToken.generate().value) == 403)
        #expect(await post(body, token: token.value, origin: "http://evil.example") == 403)
        #expect(await post(#"{"session":"other","received":0}"#, token: token.value) == 404)
        #expect(await post(#"{"session":"\#(session)","received":-1}"#, token: token.value) == 400)
        #expect(await post(#"{"session":"\#(session)"}"#, token: token.value) == 400)
        #expect(hub.takeLinkSample()?.feedback == nil)
    }

    @Test func aReplacedViewersSessionEnds() async {
        let first = hub.join(NWConnection(host: "127.0.0.1", port: 9, using: .tcp))!
        hub.join(NWConnection(host: "127.0.0.1", port: 9, using: .tcp))
        #expect(await post(#"{"session":"\#(first)","received":0}"#, token: token.value) == 404)
        #expect(hub.takeLinkSample()?.feedback == nil)
    }
}
