import Foundation
import os
import Testing
@testable import GlasstapKit

/// A viewer on a real loopback socket that reads at a fixed rate, as `scripts/slow-viewer.py` does.
/// With `reportTo`, it also reports the stream bytes it has received every 250 ms, as the page does.
/// `rtt` makes it look far away: each report carries the bytes it had read one round trip earlier,
/// as a report from a distant viewer does by the time the host has it.
final class SlowReader: @unchecked Sendable {
    private let fd: Int32
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    private let rate = OSAllocatedUnfairLock(initialState: 0)
    private let reportTo: (port: UInt16, token: String)?
    private let rtt: Duration

    init(port: UInt16, path: String, receiveBuffer: Int32, reportTo: (port: UInt16, token: String)? = nil,
         rtt: Duration = .zero) {
        self.reportTo = reportTo
        self.rtt = rtt
        fd = Self.connect(port: port, receiveBuffer: receiveBuffer)
        let request = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n"
        _ = request.withCString { send(fd, $0, strlen($0), 0) }
    }

    private static func connect(port: UInt16, receiveBuffer: Int32? = nil) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        // Before connect, so that the TCP window starts small.
        if var size = receiveBuffer {
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return fd
    }

    /// One `POST /stats` on the kept-alive control connection, as the page sends it. Opens the
    /// connection when there is none, and once more if the server closed it. Returns the socket.
    private static func report(on fd: Int32, port: UInt16, token: String, session: String, received: Int) -> Int32 {
        let body = #"{"session":"\#(session)","received":\#(received)}"#
        let request = "POST /stats HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nX-Glasstap: \(token)\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        var fd = fd
        for _ in 0..<2 {
            if fd < 0 {
                fd = connect(port: port)
                var timeout = timeval(tv_sec: 1, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            }
            let written = request.withCString { send(fd, $0, strlen($0), 0) }
            if written > 0, readResponse(fd) { return fd }
            close(fd)
            fd = -1
        }
        return fd
    }

    /// Reads one response: the header, then as many body bytes as its Content-Length says.
    private static func readResponse(_ fd: Int32) -> Bool {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            if let end = data.firstRange(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).lowercased()
                let length = head.components(separatedBy: "\r\n")
                    .first { $0.hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                if data.count - (end.upperBound - data.startIndex) >= length { return true }
            }
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { return false }
            data.append(contentsOf: buffer[0..<n])
        }
    }

    /// A new reading rate, as when the link gets faster or slower.
    func setRate(_ bytesPerSecond: Int) {
        rate.withLock { $0 = bytesPerSecond }
    }

    /// Reads `bytesPerSecond` on a thread of its own until `stop()`. The thread closes the socket,
    /// so that a read never lands on a descriptor number that was given to another socket.
    func start(bytesPerSecond: Int) {
        setRate(bytesPerSecond)
        Thread.detachNewThread { [self] in
            var rateStart = (at: ContinuousClock.now, total: 0, rate: rate.withLock { $0 })
            var buffer = [UInt8](repeating: 0, count: 1024)
            var total = 0
            // The header, then the stream body up to the config, which names the session.
            var head = Data()
            var bodyStart: Int?
            var session: String?
            var nextReport = ContinuousClock.now
            var control: Int32 = -1
            // The bytes read so far, by time, for reports that are one round trip late.
            var history: [(at: ContinuousClock.Instant, total: Int)] = [(ContinuousClock.now, 0)]
            while !stopped.withLock({ $0 }) {
                let now = ContinuousClock.now
                if let reportTo, let session, let bodyStart, now >= nextReport {
                    nextReport = now + .milliseconds(250)
                    while history.count > 1, history[1].at <= now - rtt { history.removeFirst() }
                    control = Self.report(on: control, port: reportTo.port, token: reportTo.token, session: session,
                                          received: max(0, history[0].total - bodyStart))
                }
                let current = rate.withLock { $0 }
                if current != rateStart.rate { rateStart = (now, total, current) }
                let due = Double(total - rateStart.total) / Double(current)
                let elapsed = (now - rateStart.at) / .seconds(1)
                if due > elapsed {
                    Thread.sleep(forTimeInterval: min(due - elapsed, 0.05))
                    continue
                }
                let n = recv(fd, &buffer, buffer.count, 0)
                if n <= 0 { break }
                total += n
                history.append((ContinuousClock.now, total))
                if session == nil {
                    head.append(contentsOf: buffer[0..<n])
                    if bodyStart == nil, let end = head.firstRange(of: Data("\r\n\r\n".utf8)) {
                        bodyStart = end.upperBound - head.startIndex
                        head = Data(head[end.upperBound...])
                    }
                    if bodyStart != nil {
                        var body = head
                        let config = StreamMessage.decode(&body).first { $0.type == StreamMessageType.config.rawValue }
                        session = config.flatMap { try? JSONDecoder().decode(StreamConfig.self, from: $0.payload) }?.session
                    }
                }
            }
            close(fd)
            if control >= 0 { close(control) }
        }
    }

    func stop() {
        stopped.withLock { $0 = true }
        shutdown(fd, SHUT_RDWR)
    }
}

/// The real hub, both listeners and the 250 ms tick, with one slow reader connected.
struct TestLink {
    let hub: ViewerHub
    let server: VideoServer
    let control: ControlServer
    let queue: DispatchQueue
    /// Each change of the target, with the time since the viewer connected.
    let changes: OSAllocatedUnfairLock<[(at: Duration, change: BitrateController.Change)]>
    let adapter: RateAdapter
    let reader: SlowReader
    let token: AccessToken

    /// The video listener takes `port` and the control listener `port - 1`. Each test has its own,
    /// because the listeners of the test before may still be closing. `reporting` makes the reader
    /// report like the page.
    static func connect(port: UInt16, configured: StreamStats = StreamStats(bitrate: 800_000, fps: 30),
                        reporting: Bool, rtt: Duration = .zero) async throws -> TestLink {
        let token = AccessToken.generate()
        let videoState = OSAllocatedUnfairLock(initialState: ListenerState.stopped)
        let controlState = OSAllocatedUnfairLock(initialState: ListenerState.stopped)
        let hub = ViewerHub()
        let queue = DispatchQueue(label: "glasstap.test-rate")
        let changes = OSAllocatedUnfairLock(initialState: [(at: Duration, change: BitrateController.Change)]())
        let start = ContinuousClock.now
        let adapter = RateAdapter(hub: hub, queue: queue, configured: configured) { change in
            changes.withLock { $0.append((ContinuousClock.now - start, change)) }
        }
        // As the capture engine does.
        hub.setJoinHandler { queue.async { adapter.viewerJoined() } }
        let server = VideoServer(port: port, controlPort: port - 1, token: token, hub: hub,
                                 onState: { s in videoState.withLock { $0 = s } })
        let control = ControlServer(port: port - 1, videoPort: port, token: token,
                                    wda: WDAClient(baseURL: URL(string: "http://127.0.0.1:1")!), hub: hub,
                                    pageTemplate: nil, onState: { s in controlState.withLock { $0 = s } })
        server.start()
        control.start()
        for _ in 0..<100 where videoState.withLock({ $0 }) != .ready || controlState.withLock({ $0 }) != .ready {
            try await Task.sleep(for: .milliseconds(20))
        }
        let reader = SlowReader(port: port, path: "/video?token=\(token.value)&stats=1", receiveBuffer: 16384,
                                reportTo: reporting ? (port - 1, token.value) : nil, rtt: rtt)
        for _ in 0..<100 where hub.viewerCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(hub.viewerCount == 1)
        return TestLink(hub: hub, server: server, control: control, queue: queue, changes: changes,
                        adapter: adapter, reader: reader, token: token)
    }

    func stop() {
        reader.stop()
        server.stop()
        control.stop()
    }

    /// Sends 30 frames a second for at most `seconds`, with a key frame every 2 s or when the hub asks,
    /// and starts the tick with each frame, as the capture engine does. Returns when `until` is true.
    func stream(seconds: Int, delta: ClosedRange<Int>, key: ClosedRange<Int>,
                until done: ([BitrateController.Change]) -> Bool = { !$0.isEmpty }) async throws {
        let config = StreamConfig(codec: CodecString.hevc, width: 590, height: 1278)
        var lastKey = ContinuousClock.now
        for _ in 0..<(30 * seconds) {
            let isKey = hub.isWaitingForKeyFrame || ContinuousClock.now - lastKey > .seconds(2)
            if isKey { lastKey = ContinuousClock.now }
            let size = Int.random(in: isKey ? key : delta)
            hub.broadcast(StreamMessage.encode(isKey ? .keyFrame : .deltaFrame, Data(count: size)),
                          key: isKey, config: config)
            queue.async { [adapter] in adapter.start() }
            if done(changes.withLock { $0.map(\.change) }) { return }
            try await Task.sleep(for: .milliseconds(33))
        }
    }

    var firstChange: (at: Duration, change: BitrateController.Change)? { changes.withLock { $0.first } }
}

@Suite(.serialized) struct SlowLinkTests {
    let configured = StreamStats(bitrate: 800_000, fps: 30)

    /// An old page sends no reports. The host-side backlog sees a link that is far too slow.
    @Test func aViewerThatNeverReportsIsCutByTheHostSideSignal() async throws {
        let link = try await TestLink.connect(port: 39321, reporting: false)
        defer { link.server.stop(); link.control.stop() }
        link.reader.start(bytesPerSecond: 20_000)
        // About 375 KB/s for a 20 KB/s reader.
        try await link.stream(seconds: 8, delta: 5_000...20_000, key: 40_000...80_000)
        let cut = try #require(link.firstChange)
        #expect(cut.at < .seconds(3))
        #expect(cut.change.target.bitrate == 560_000)
        guard case .congested = cut.change.reason else {
            Issue.record("first change: \(cut.change.reason)")
            return
        }
        // With no viewer, the next tick goes back to the settings and the tick stops.
        link.reader.stop()
        for _ in 0..<100 where link.changes.withLock({ $0.count }) < 2 { try await Task.sleep(for: .milliseconds(20)) }
        let last = link.changes.withLock { $0.last }
        #expect(last?.change.reason == .noViewer)
        #expect(last?.change.target == configured)
    }

    /// A screen that changes little sends only a little more than the link carries. Network.framework
    /// reports each send as processed once its own buffer takes it, and that buffer holds about 0.5 MB
    /// on loopback, so the host-side signal alone saw this only after about 25 s. The viewer's
    /// reports show the queue at once.
    @Test func aModestSurplusIsSeenWithinSeconds() async throws {
        let link = try await TestLink.connect(port: 39323, reporting: true)
        defer { link.stop() }
        link.reader.start(bytesPerSecond: 20_000)
        // About 43 KB/s for a 20 KB/s reader.
        try await link.stream(seconds: 10, delta: 1_000...2_000, key: 30_000...40_000)
        let cut = try #require(link.firstChange, "no cut in 10 s")
        #expect(cut.at < .seconds(6))
        guard case .queued = cut.change.reason else {
            Issue.record("first change: \(cut.change.reason)")
            return
        }
    }

    /// A viewer that takes the stream from a slow one may have a good link. It starts from the settings.
    @Test func aNewViewerStartsFromTheSettings() async throws {
        let link = try await TestLink.connect(port: 39327, reporting: true)
        defer { link.stop() }
        link.reader.start(bytesPerSecond: 20_000)
        try await link.stream(seconds: 10, delta: 2_500...3_500, key: 40_000...60_000)
        #expect(link.firstChange?.change.target.bitrate == 560_000)
        let next = SlowReader(port: 39327, path: "/video?token=\(link.token.value)&stats=1", receiveBuffer: 16384)
        defer { next.stop() }
        for _ in 0..<100 where link.changes.withLock({ $0.last?.change.reason }) != .newViewer {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(link.changes.withLock { $0.last?.change }
            == .init(target: configured, size: BitrateController.ladder(width: 590)[0], reason: .newViewer))
    }

    @Test func aReportingViewerThatKeepsUpIsLeftAlone() async throws {
        let link = try await TestLink.connect(port: 39325, reporting: true)
        defer { link.stop() }
        link.reader.start(bytesPerSecond: 10_000_000)
        try await link.stream(seconds: 4, delta: 1_000...2_000, key: 30_000...40_000)
        #expect(link.changes.withLock { $0.map(\.change) } == [])
        // The reports arrive: the tick sees the viewer's feedback, not only the host's.
        #expect(link.hub.takeLinkSample()?.feedback != nil)
    }
}

/// A distant viewer: its reports come one round trip of 300 ms late, as through a WAN tunnel.
/// About 2 round trips of stream are always on the way, and that must not count as a queue.
@Suite(.serialized) struct DelayedLinkTests {
    let rtt = Duration.milliseconds(300)
    let configured = StreamStats(bitrate: 800_000, fps: 30)
    /// About 120 KB/s, a little over 800 kbit/s.
    let delta = 2_500...3_500
    let key = 40_000...60_000

    @Test func aViewerThatKeepsUpIsLeftAlone() async throws {
        let link = try await TestLink.connect(port: 39341, reporting: true, rtt: rtt)
        defer { link.stop() }
        link.reader.start(bytesPerSecond: 10_000_000)
        try await link.stream(seconds: 10, delta: delta, key: key)
        #expect(link.changes.withLock { $0.map(\.change) } == [])
        #expect(link.hub.takeLinkSample()?.feedback != nil)
    }

    @Test func aSlowViewerIsCutAndTheTargetComesBackWhenTheLinkRecovers() async throws {
        let link = try await TestLink.connect(port: 39343, reporting: true, rtt: rtt)
        defer { link.stop() }
        link.reader.start(bytesPerSecond: 20_000)
        try await link.stream(seconds: 10, delta: delta, key: key)
        let cut = try #require(link.firstChange, "no cut in 10 s")
        #expect(cut.change.target.bitrate < configured.bitrate)
        // The link recovers. The queue drains with no further cut, and the target climbs back to the settings.
        let cuts = link.changes.withLock { $0.count }
        link.reader.setRate(10_000_000)
        try await link.stream(seconds: 30, delta: delta, key: key) { $0.last?.target == configured }
        let changes = link.changes.withLock { $0.map(\.change) }
        #expect(changes.last?.target == configured, "\(changes.map(\.target))")
        #expect(changes.dropFirst(cuts).allSatisfy { $0.reason == .clear }, "\(changes.map(\.reason))")
    }

    /// At the lowest bitrate, one key frame is many times the bytes of a quarter second.
    /// It is the normal shape of the stream, not congestion.
    @Test func aKeyFrameAloneDoesNotCutAtTheFloor() async throws {
        let floor = StreamStats(bitrate: 150_000, fps: 30)
        let link = try await TestLink.connect(port: 39345, configured: floor, reporting: true, rtt: rtt)
        defer { link.stop() }
        // About 21 KB/s on average, with a 30 KB key frame every 2 s, on a 30 KB/s link.
        link.reader.start(bytesPerSecond: 30_000)
        try await link.stream(seconds: 10, delta: 150...250, key: 30_000...30_000)
        #expect(link.changes.withLock { $0.map(\.change) } == [])
    }
}
