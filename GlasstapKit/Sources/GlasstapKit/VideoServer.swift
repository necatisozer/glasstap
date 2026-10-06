import Foundation
import Network

/// Serves the stream to the newest viewer on 127.0.0.1:<port>/video.
public final class VideoServer: @unchecked Sendable {
    private let token: AccessToken
    private let hub: ViewerHub
    private let listener: LoopbackListener
    // Touched only on `listener.queue`.
    private var viewerOrigins: Set<String>

    /// `controlPort` gives the origin of the viewer page, which alone may read the stream.
    public init(port: UInt16, controlPort: UInt16, token: AccessToken, hub: ViewerHub,
                onState: @escaping @Sendable (ListenerState) -> Void) {
        self.token = token
        self.hub = hub
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
            hub.leaveAll()
        }
    }

    public func stop() {
        listener.stop { [hub] in hub.leaveAll() }
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed, .cancelled:
                if let connection { self?.hub.leave(connection) }
            default: break
            }
        }
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
            var headers = [("Content-Type", "application/octet-stream"), ("Cache-Control", "no-store")]
            if let corsOrigin { headers += [("Access-Control-Allow-Origin", corsOrigin), ("Vary", "Origin")] }
            let header = HTTPResponse(status: 200, headers: headers).header(contentLength: nil)
            connection.send(content: header, completion: .contentProcessed { _ in })
            hub.join(connection)
            watchForClose(connection)
        }
    }

    /// The viewer sends nothing after its request. Keep one receive open anyway, so that a
    /// closed tab is noticed at once and not only when a later send fails.
    private func watchForClose(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                hub.leave(connection)
            } else {
                watchForClose(connection)
            }
        }
    }
}
