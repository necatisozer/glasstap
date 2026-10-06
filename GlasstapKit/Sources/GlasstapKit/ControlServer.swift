import Foundation
import Network
import os

/// Serves the viewer page and the actions on 127.0.0.1:<port>.
public final class ControlServer: @unchecked Sendable {
    private let token: AccessToken
    private let wda: WDAClient
    /// Takes the viewer's reports of the bytes it has received, for adaptive bitrate.
    private let hub: ViewerHub?
    /// The viewer HTML with its `__VIDEO_PORT__` placeholder.
    private let pageTemplate: String?
    /// The page as served, built once for each video port.
    private let page: OSAllocatedUnfairLock<Data?>
    private let listener: LoopbackListener
    private let log = Logger(subsystem: "io.github.necatisozer.glasstap", category: "control-server")

    /// `pageTemplate` is the viewer HTML. The page learns the video port from this server.
    public init(port: UInt16, videoPort: UInt16, token: AccessToken, wda: WDAClient, hub: ViewerHub? = nil,
                pageTemplate: String?, onState: @escaping @Sendable (ListenerState) -> Void) {
        self.token = token
        self.wda = wda
        self.hub = hub
        self.pageTemplate = pageTemplate
        page = OSAllocatedUnfairLock(initialState: Self.page(pageTemplate, videoPort: videoPort))
        listener = LoopbackListener(name: "control-server", port: port, onState: onState)
    }

    public func start() {
        listener.start { [weak self] in self?.accept($0) }
    }

    public func stop() {
        listener.stop()
    }

    /// A change of the video port needs no restart of this listener.
    public func setVideoPort(_ port: UInt16) {
        let new = Self.page(pageTemplate, videoPort: port)
        page.withLock { $0 = new }
    }

    private static func page(_ template: String?, videoPort: UInt16) -> Data? {
        template.map { Data($0.replacingOccurrences(of: "__VIDEO_PORT__", with: String(videoPort)).utf8) }
    }

    /// A connection that waits this long for its next request is closed.
    static let idleTimeout: DispatchTimeInterval = .seconds(30)

    private func accept(_ connection: NWConnection) {
        connection.start(queue: listener.queue)
        serve(connection, idle: IdleTimer(connection: connection, queue: listener.queue))
    }

    /// Answers requests on `connection` until the client asks to close it or it stays idle.
    /// The viewer reports four times a second. Through `ssh -L`, each new connection opens a new
    /// SSH channel, which costs a round trip, so the page keeps one connection open.
    private func serve(_ connection: NWConnection, idle: IdleTimer) {
        idle.arm(Self.idleTimeout)
        Listener.readRequest(connection) { [weak self] request in
            idle.disarm()
            guard let self else { return connection.cancel() }
            let keepAlive = request.header("connection")?.lowercased() != "close"
            Task {
                let response = await self.response(to: request)
                if keepAlive {
                    Listener.respond(connection, response) { [weak server = self] in server?.serve(connection, idle: idle) }
                } else {
                    Listener.respond(connection, response)
                }
            }
        }
    }

    func response(to request: HTTPRequest) async -> HTTPResponse {
        guard Auth.controlAllows(request, token: token) else { return .text(403, "forbidden") }
        if request.method == "GET", request.path == "/" {
            guard let body = page.withLock({ $0 }) else { return .text(404, "the viewer page is missing from the app") }
            return HTTPResponse(status: 200, headers: [("Content-Type", "text/html; charset=utf-8")], body: body)
        }
        if request.method == "POST", request.path == "/stats" { return statsResponse(to: request) }
        do {
            return try await wdaResponse(to: request)
        } catch {
            log.error("\(request.method) \(request.path) failed: \(String(describing: error), privacy: .public)")
            return .text(502, String(describing: error))
        }
    }

    /// The requests that WDA answers. A WDA failure throws, and the caller turns it into 502.
    private func wdaResponse(to request: HTTPRequest) async throws -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/screenshot"):
            let png = try await wda.screenshot()
            return HTTPResponse(status: 200, headers: [
                ("Content-Type", "image/png"),
                ("Content-Disposition", "attachment; filename=\"\(Self.screenshotName())\""),
            ], body: png)
        case ("GET", "/info"):
            return .json(try JSONEncoder().encode(try await wda.windowSize()))
        case ("POST", _):
            let kind = request.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let action: ControlAction
            do {
                action = try ControlAction.parse(kind: kind, body: request.body)
            } catch .unknownAction {
                return .text(404, "not found")
            } catch {
                return .text(400, "bad request")
            }
            try await wda.perform(action)
            return .json(Data("{}".utf8))
        default:
            return .text(404, "not found")
        }
    }

    private struct StatsReport: Decodable {
        let session: String
        /// The bytes of the stream body that the viewer has received.
        let received: Int
    }

    private static let decoder = JSONDecoder()

    /// `POST /stats` {"session", "received"}: the viewer's report for adaptive bitrate.
    private func statsResponse(to request: HTTPRequest) -> HTTPResponse {
        guard let report = try? Self.decoder.decode(StatsReport.self, from: request.body), report.received >= 0 else {
            return .text(400, "bad request")
        }
        // A report for a stream that ended or that another viewer took changes nothing.
        guard hub?.report(session: report.session, received: report.received) == true else {
            return .text(404, "unknown session")
        }
        return .json(Data("{}".utf8))
    }

    static func screenshotName(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "'iphone-'yyyyMMdd-HHmmss'.png'"
        return f.string(from: date)
    }
}

/// Closes a kept-alive connection that waits too long for its next request.
/// One timer for each connection, armed again before each read.
private final class IdleTimer: @unchecked Sendable {
    private let timer: DispatchSourceTimer

    init(connection: NWConnection, queue: DispatchQueue) {
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { connection.cancel() }
        timer.resume()
    }

    func arm(_ timeout: DispatchTimeInterval) {
        timer.schedule(deadline: .now() + timeout)
    }

    func disarm() {
        timer.schedule(deadline: .distantFuture)
    }

    deinit {
        timer.cancel()
    }
}
