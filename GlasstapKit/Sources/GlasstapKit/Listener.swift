import Foundation
import Network
import os

public enum ListenerState: Sendable, Equatable {
    case stopped
    case ready
    case failed(String)
}

/// The lifecycle of one loopback listener, shared by both servers. Its queue also
/// serves the connections, and the server keeps its own state on it.
final class LoopbackListener: @unchecked Sendable {
    let queue: DispatchQueue
    private let port: UInt16
    private let onState: @Sendable (ListenerState) -> Void
    private let log: Logger
    // Touched only on `queue`.
    private var listener: NWListener?

    init(name: String, port: UInt16, onState: @escaping @Sendable (ListenerState) -> Void) {
        queue = DispatchQueue(label: "glasstap.\(name)")
        log = Logger(subsystem: "io.github.necatisozer.glasstap", category: name)
        self.port = port
        self.onState = onState
    }

    func start(accept: @escaping @Sendable (NWConnection) -> Void) {
        queue.async { [self] in
            do {
                let listener = try Listener.loopback(port: port)
                listener.newConnectionHandler = accept
                listener.stateUpdateHandler = { [log, port, onState] state in
                    guard let mapped = Listener.state(state) else { return }
                    if case let .failed(e) = mapped { log.error("listener on \(port) failed: \(e, privacy: .public)") }
                    onState(mapped)
                }
                listener.start(queue: queue)
                self.listener = listener
            } catch {
                onState(.failed(error.localizedDescription))
            }
        }
    }

    /// Stops listening. The handlers go first, so that a stopped listener reports nothing more.
    func stop(then cleanup: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            listener?.stateUpdateHandler = nil
            listener?.newConnectionHandler = nil
            listener?.cancel()
            listener = nil
            cleanup?()
        }
    }
}

enum Listener {
    /// A TCP listener on 127.0.0.1 only. Nothing outside this Mac can connect.
    static func loopback(port: UInt16) throws -> NWListener {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
        let params = NWParameters.tcp
        // A restart can bind the port again at once. This does not let another
        // process bind the same port: a second bind, even with SO_REUSEPORT, fails (tested).
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
        return try NWListener(using: params)
    }

    static func state(_ state: NWListener.State) -> ListenerState? {
        switch state {
        case .ready: .ready
        case let .failed(error): .failed(error.localizedDescription)
        case .cancelled: .stopped
        default: nil
        }
    }

    /// Reads one HTTP request. A malformed request gets 400; a closed connection is dropped.
    static func readRequest(_ connection: NWConnection, buffer: Data = Data(),
                            then handle: @escaping @Sendable (HTTPRequest) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPParser.parse(buffer) {
            case let .complete(request):
                handle(request)
            case .invalid:
                respond(connection, .text(400, "bad request"))
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    readRequest(connection, buffer: buffer, then: handle)
                }
            }
        }
    }

    /// Sends the response. Without `next`, it then closes the connection. With it, the connection
    /// stays open, and `next` reads the next request.
    static func respond(_ connection: NWConnection, _ response: HTTPResponse,
                        keepAlive next: (@Sendable () -> Void)? = nil) {
        connection.send(content: response.serialized(keepAlive: next != nil), completion: .contentProcessed { error in
            if let next, error == nil { next() } else { connection.cancel() }
        })
    }
}
