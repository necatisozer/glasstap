import Foundation
import Network
import os

/// The viewer registry on the frame path. A lock, not an actor, guards it,
/// so that each frame goes out without a hop to another executor.
public final class ViewerHub: @unchecked Sendable {
    private struct State {
        var viewers = ViewerState<ObjectIdentifier>()
        var connections: [ObjectIdentifier: NWConnection] = [:]
        var onKeyFrameWanted: (@Sendable () -> Void)?
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let log = Logger(subsystem: "io.github.necatisozer.glasstap", category: "viewers")

    public init() {}

    public var viewerCount: Int { state.withLock { $0.viewers.count } }

    /// True while a viewer waits for a key frame. It stays true until a key frame goes out,
    /// so a frame that the encoder drops does not leave the viewer without a picture.
    public var isWaitingForKeyFrame: Bool { state.withLock { $0.viewers.wantKeyFrame } }

    /// Called when a viewer starts to wait for a key frame: when it joins, or when its
    /// backlog has drained. The screen may be still, so the capture must encode its last frame.
    func setKeyFrameHandler(_ handler: @escaping @Sendable () -> Void) {
        state.withLock { $0.onKeyFrameWanted = handler }
    }

    /// Makes `connection` the only viewer. Call it after the HTTP header is sent.
    func join(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let (old, handler) = state.withLock { s -> ([NWConnection], (@Sendable () -> Void)?) in
            let replaced = s.viewers.join(id)
            s.connections[id] = connection
            return (replaced.compactMap { s.connections.removeValue(forKey: $0) }, s.onKeyFrameWanted)
        }
        // Tell the old viewer, so that it stops and does not take the stream back.
        for c in old {
            c.send(content: StreamMessage.encode(.replaced), completion: .contentProcessed { _ in c.cancel() })
        }
        log.info("viewer joined, \(old.count) replaced")
        handler?()
    }

    func leave(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let removed = state.withLock { s -> NWConnection? in
            s.viewers.leave(id)
            return s.connections.removeValue(forKey: id)
        }
        if let removed {
            removed.cancel()
            log.info("viewer left")
        }
    }

    /// Closes every viewer, for a restart of the video listener.
    func leaveAll() {
        let all = state.withLock { s -> [NWConnection] in
            for id in s.connections.keys { s.viewers.leave(id) }
            defer { s.connections.removeAll() }
            return Array(s.connections.values)
        }
        all.forEach { $0.cancel() }
    }

    /// Sends one frame message to the viewer. Call it from one thread at a time, in frame order.
    public func broadcast(_ message: Data, key: Bool, config: StreamConfig?) {
        let deliveries = state.withLock { s in
            s.viewers.frame(message, key: key, config: config).compactMap { d in
                s.connections[d.id].map { (connection: $0, messages: d.messages) }
            }
        }
        for (connection, messages) in deliveries {
            for message in messages {
                connection.send(content: message, completion: .contentProcessed { [weak self] error in
                    self?.sent(connection, error: error)
                })
            }
        }
    }

    private func sent(_ connection: NWConnection, error: NWError?) {
        // The closure keeps the connection alive, so its identifier cannot belong to a newer one.
        let handler = state.withLock { s -> (@Sendable () -> Void)? in
            let wanted = s.viewers.wantKeyFrame
            s.viewers.sent(ObjectIdentifier(connection))
            return !wanted && s.viewers.wantKeyFrame ? s.onKeyFrameWanted : nil
        }
        handler?()
        if error != nil { leave(connection) }
    }
}
