import Foundation
import Network
import os

/// The viewer registry on the frame path. A lock, not an actor, guards it,
/// so that each frame goes out without a hop to another executor.
public final class ViewerHub: @unchecked Sendable {
    private struct State {
        var viewers = ViewerState<ObjectIdentifier>()
        var connections: [ObjectIdentifier: NWConnection] = [:]
        /// The encoder's target. Only the capture engine writes it.
        var stats: StreamStats?
        var onKeyFrameWanted: (@Sendable () -> Void)?
        var onJoin: (@Sendable () -> Void)?
        /// Set when the iPhone's session stops. A viewer that joins after it would wait forever.
        var closed = false
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let log = Logger(subsystem: "io.github.necatisozer.glasstap", category: "viewers")
    private let epoch = ContinuousClock.now
    private var now: Duration { ContinuousClock.now - epoch }

    public init() {}

    public var viewerCount: Int { state.withLock { $0.viewers.count } }

    /// The encoder's target, as the viewers see it in stats messages.
    public var stats: StreamStats? { state.withLock { $0.stats } }

    /// True while a viewer waits for a key frame. It stays true until a key frame goes out,
    /// so a frame that the encoder drops does not leave the viewer without a picture.
    public var isWaitingForKeyFrame: Bool { state.withLock { $0.viewers.wantKeyFrame } }

    /// Called when a viewer starts to wait for a key frame: when it joins, or when its
    /// backlog has drained. The screen may be still, so the capture must encode its last frame.
    func setKeyFrameHandler(_ handler: @escaping @Sendable () -> Void) {
        state.withLock { $0.onKeyFrameWanted = handler }
    }

    /// Called after a viewer joins, before it gets any stats. Adaptive bitrate starts again from
    /// the settings for each viewer, because a new viewer may have another link.
    func setJoinHandler(_ handler: @escaping @Sendable () -> Void) {
        state.withLock { $0.onJoin = handler }
    }

    /// Makes `connection` the only viewer, and sends `header` to it first. `stats` is true for a
    /// viewer that reads stats messages. Returns the session of the new stream, or nil if the hub is
    /// closed: then nothing is sent, and the caller answers the request.
    @discardableResult
    func join(_ connection: NWConnection, stats: Bool = false, header: Data? = nil) -> String? {
        let id = ObjectIdentifier(connection)
        // 32 random hex characters. The token guards the reports; the session only names the stream.
        let session = AccessToken.generate().value
        let joined = state.withLock { s -> (old: [NWConnection], onJoin: (@Sendable () -> Void)?, onKeyFrameWanted: (@Sendable () -> Void)?)? in
            // Checked under the lock, so a join and a close cannot both win.
            guard !s.closed else { return nil }
            // Sent under the lock too: once the viewer is in the list, another thread may send it a frame,
            // and the header must go out before it. A send only queues the data.
            if let header { connection.send(content: header, completion: .contentProcessed { _ in }) }
            let replaced = s.viewers.join(id, stats: stats, session: session)
            s.connections[id] = connection
            return (replaced.compactMap { s.connections.removeValue(forKey: $0) }, s.onJoin, s.onKeyFrameWanted)
        }
        guard let (old, onJoin, onKeyFrameWanted) = joined else { return nil }
        // Tell the old viewer, so that it stops and does not take the stream back.
        for c in old {
            c.send(content: StreamMessage.encode(.replaced), completion: .contentProcessed { _ in c.cancel() })
        }
        log.info("viewer joined, \(old.count) replaced")
        onJoin?()
        // The new viewer learns the target at once, not only at its next change.
        if let current = state.withLock({ $0.stats }) { setStats(current) }
        onKeyFrameWanted?()
        return session
    }

    /// Stores the target and sends it to each viewer that reads stats and does not have it yet.
    func setStats(_ stats: StreamStats) {
        let now = self.now
        let deliveries = state.withLock { s in
            s.stats = stats
            return s.viewers.stats(stats, at: now).compactMap { d in s.connections[d.id].map { ($0, d.message) } }
        }
        for (connection, message) in deliveries { send(message, on: connection) }
    }

    /// One measurement of the link, or nil when no viewer is connected.
    func takeLinkSample() -> LinkSample? {
        let now = self.now
        return state.withLock { $0.viewers.takeSample(at: now) }
    }

    /// A viewer's report of the stream bytes that it has received. Returns false if `session`
    /// is not a current stream, for example after another viewer took it.
    func report(session: String, received: Int) -> Bool {
        let now = self.now
        return state.withLock { $0.viewers.report(session: session, received: received, at: now) }
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

    /// Closes every viewer for good, when the iPhone's session stops. Later joins fail.
    func close() {
        state.withLock { $0.closed = true }
        leaveAll()
    }

    var isClosed: Bool { state.withLock { $0.closed } }

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
        let now = self.now
        let deliveries = state.withLock { s in
            s.viewers.frame(message, key: key, config: config, at: now).compactMap { d in
                s.connections[d.id].map { (connection: $0, messages: d.messages) }
            }
        }
        for (connection, messages) in deliveries {
            for message in messages { send(message, on: connection) }
        }
    }

    /// Every send to a viewer goes through here, so that its completion reaches the viewer's backlog and send times.
    private func send(_ message: Data, on connection: NWConnection) {
        connection.send(content: message, completion: .contentProcessed { [weak self] error in
            self?.sent(connection, error: error)
        })
    }

    private func sent(_ connection: NWConnection, error: NWError?) {
        let now = self.now
        // The closure keeps the connection alive, so its identifier cannot belong to a newer one.
        let handler = state.withLock { s -> (@Sendable () -> Void)? in
            let wanted = s.viewers.wantKeyFrame
            s.viewers.sent(ObjectIdentifier(connection), at: now)
            return !wanted && s.viewers.wantKeyFrame ? s.onKeyFrameWanted : nil
        }
        handler?()
        if error != nil { leave(connection) }
    }
}
