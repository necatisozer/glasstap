import Foundation
import Network

/// Serves each iPhone's stream to its newest viewer on 127.0.0.1:<port>, at `/devices/<id>/video`,
/// or at `/video` while only one iPhone is connected.
public final class VideoServer: @unchecked Sendable {
    private let token: AccessToken
    private let devices: DeviceDirectory
    private let listener: LoopbackListener
    // Touched only on `listener.queue`.
    private var viewerOrigins: Set<String>

    /// `controlPort` gives the origin of the viewer page, which alone may read the stream.
    public init(port: UInt16, controlPort: UInt16, token: AccessToken, devices: DeviceDirectory,
                onState: @escaping @Sendable (ListenerState) -> Void) {
        self.token = token
        self.devices = devices
        viewerOrigins = Auth.viewerOrigins(controlPort: controlPort)
        listener = LoopbackListener(name: "video-server", port: port, onState: onState)
    }

    public func start() {
        listener.start { [weak self] in self?.accept($0) }
    }

    /// The viewer page moved to another port. Its old origin loses access.
    public func setControlPort(_ port: UInt16) {
        listener.queue.async { [self] in
            viewerOrigins = Auth.viewerOrigins(controlPort: port)
            devices.leaveAll()
        }
    }

    public func stop() {
        listener.stop { [devices] in devices.leaveAll() }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: listener.queue)
        Listener.readRequest(connection) { [weak self] request in
            self?.handle(request, on: connection)
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        switch Auth.video(request, token: token, viewerOrigins: viewerOrigins) {
        case let .reject(status):
            Listener.respond(connection, .text(status, status == 404 ? "not found" : "forbidden"))
        case let .accept(corsOrigin):
            let cors = corsOrigin.map { [("Access-Control-Allow-Origin", $0), ("Vary", "Origin")] } ?? []
            // Auth accepts only a path that parses. The iPhone is checked after the token,
            // so that a request without it learns nothing about the iPhones.
            guard case let .route(id, _)? = DevicePath.parse(request.path) else { return connection.cancel() }
            let hub: ViewerHub
            switch devices.route(id) {
            case let .success(route): hub = route.hub
            case let .failure(error):
                // The page reads the reason, so the answer carries the CORS header too.
                var response = HTTPResponse.text(error.status, error.message)
                response.headers += cors
                return Listener.respond(connection, response)
            }
            // Each iPhone has its own hub, so the close of a connection must reach the hub that it joined.
            connection.stateUpdateHandler = { [weak connection] state in
                switch state {
                case .failed, .cancelled:
                    if let connection { hub.leave(connection) }
                default: break
                }
            }
            let headers = [("Content-Type", "application/octet-stream"), ("Cache-Control", "no-store")] + cors
            let header = HTTPResponse(status: 200, headers: headers).header(contentLength: nil)
            // The session may have stopped since the lookup, for example because the iPhone was unplugged.
            guard hub.join(connection, stats: request.queryValue("stats") == "1", header: header) != nil else {
                var response = HTTPResponse.text(409, "This iPhone is no longer connected.")
                response.headers += cors
                return Listener.respond(connection, response)
            }
            watchForClose(connection, hub: hub)
        }
    }

    /// The viewer sends nothing after its request. Keep one receive open anyway, so that a
    /// closed tab is noticed at once and not only when a later send fails.
    private func watchForClose(_ connection: NWConnection, hub: ViewerHub) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                hub.leave(connection)
            } else {
                watchForClose(connection, hub: hub)
            }
        }
    }
}
