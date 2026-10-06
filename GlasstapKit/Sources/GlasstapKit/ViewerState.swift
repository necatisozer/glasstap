import Foundation

/// Who gets which stream message, and what each viewer's link looks like. Pure state, so that
/// the rules are testable without a network; `ViewerHub` applies the results to real connections.
/// Times are `Duration`s since a fixed point, from the caller.
public struct ViewerState<ID: Hashable & Sendable>: Sendable {
    /// A viewer more than this many messages behind skips to the next key frame.
    public static var maxPending: Int { 15 }
    /// A viewer that skipped takes a key frame again only when its backlog is this short.
    /// The gap to `maxPending` keeps a link at its limit from getting a key frame every few sends.
    public static var resumePending: Int { maxPending / 2 }

    struct Viewer: Sendable {
        let wantsStats: Bool
        let session: String?
        var needKey = true
        /// When each message that still waits to be sent was handed over, oldest first.
        /// The sends on one connection complete in order.
        var waiting: [Duration] = []
        /// The slowest send since the last sample, from hand-over to completion.
        var slowestSend: Duration = .zero
        /// The bytes handed over, and the viewer's reports of the bytes it has received.
        var link = LinkFeedback()
        /// The stats that this viewer got last.
        var stats: StreamStats?

        var pending: Int { waiting.count }
    }

    private var viewers: [ID: Viewer] = [:]
    private var bySession: [String: ID] = [:]
    /// The config of the current stream. Each viewer gets it with its own session.
    private var config: StreamConfig?
    /// True while some viewer waits for a key frame and can take one. Only a key frame clears it.
    public private(set) var wantKeyFrame = true

    public init() {}

    public var count: Int { viewers.count }
    /// The messages that wait to be sent, for the viewer furthest behind.
    public var backlog: Int { viewers.values.map(\.pending).max() ?? 0 }
    func contains(_ id: ID) -> Bool { viewers[id] != nil }

    /// Adds a viewer and returns the viewers that it replaces. Keep only the newest
    /// viewer: viewers can share one tunnel, so one that stops reading would stall the others.
    /// `stats` is true for a viewer that reads stats messages. `session` goes into its config message.
    public mutating func join(_ id: ID, stats: Bool = false, session: String? = nil) -> [ID] {
        let old = viewers.keys.filter { $0 != id }
        viewers = [id: Viewer(wantsStats: stats, session: session)]
        bySession = session.map { [$0: id] } ?? [:]
        wantKeyFrame = true
        return old
    }

    @discardableResult
    public mutating func leave(_ id: ID) -> Bool {
        guard let v = viewers.removeValue(forKey: id) else { return false }
        if let session = v.session { bySession[session] = nil }
        return true
    }

    /// The one path for every message to a viewer: it counts the bytes, the backlog and the send time.
    private static func enqueue(_ message: Data, to v: inout Viewer, at now: Duration) {
        v.waiting.append(now)
        v.link.add(sent: message.count)
    }

    /// A send to the viewer has completed.
    public mutating func sent(_ id: ID, at now: Duration = .zero) {
        guard var v = viewers[id], !v.waiting.isEmpty else { return }
        v.slowestSend = max(v.slowestSend, now - v.waiting.removeFirst())
        viewers[id] = v
        // A viewer that waited for its backlog to drain can take a key frame now.
        if v.needKey && v.pending <= Self.resumePending { wantKeyFrame = true }
    }

    /// The stats message for each viewer that reads stats and has not got this value yet.
    /// A viewer far behind takes it too: it is small, and the change matters most then.
    public mutating func stats(_ stats: StreamStats, at now: Duration = .zero) -> [(id: ID, message: Data)] {
        let message = StreamMessage.encode(.stats, stats.json)
        var out: [(ID, Data)] = []
        for (id, var v) in viewers where v.wantsStats && v.stats != stats {
            v.stats = stats
            Self.enqueue(message, to: &v, at: now)
            viewers[id] = v
            out.append((id, message))
        }
        return out
    }

    /// Distributes one framed frame message. `config` comes with each key frame and is
    /// stored before the frame goes out. Returns the messages for each viewer, in order.
    public mutating func frame(_ message: Data, key: Bool, config newConfig: StreamConfig? = nil,
                               at now: Duration = .zero) -> [(id: ID, messages: [Data])] {
        if key, let newConfig {
            // A new codec or size needs a decoder reset, so every viewer starts again from a key frame.
            if newConfig != config {
                config = newConfig
                for id in viewers.keys { viewers[id]?.needKey = true }
            }
        }
        var out: [(ID, [Data])] = []
        for (id, var v) in viewers {
            // A viewer too far behind skips frames until its backlog drains. Only then does it
            // ask for a key frame, so that a congested link does not get one forced key frame after another.
            if v.pending > Self.maxPending {
                v.needKey = true
                viewers[id] = v
                continue
            }
            var messages: [Data] = []
            if v.needKey {
                guard key, let config, v.pending <= Self.resumePending else { continue }
                v.needKey = false
                var own = config
                own.session = v.session
                messages.append(StreamMessage.encode(.config, own.json))
            }
            messages.append(message)
            for m in messages { Self.enqueue(m, to: &v, at: now) }
            if key { v.link.add(keyFrame: message.count, at: now) }
            viewers[id] = v
            out.append((id, messages))
        }
        // The request stays until a key frame reaches every viewer that can take one.
        // A frame that the encoder drops therefore leaves it in place.
        if key { wantKeyFrame = viewers.values.contains { $0.needKey && $0.pending <= Self.resumePending } }
        return out
    }

    /// A viewer's report of the stream bytes that it has received. Returns false if `session`
    /// is not a current stream, for example after another viewer took it.
    public mutating func report(session: String, received: Int, at now: Duration) -> Bool {
        guard let id = bySession[session] else { return false }
        viewers[id]?.link.report(received: received, at: now)
        return true
    }

    /// One measurement of the link, or nil with no viewer. A fresh report from the viewer decides.
    /// Without one, the host's own backlog and the slowest send are the safety net, for example
    /// when the reports cannot get through. A send that still waits counts with its age so far.
    public mutating func takeSample(at now: Duration) -> LinkSample? {
        guard !viewers.isEmpty else { return nil }
        var feedback: ViewerFeedback?
        for v in viewers.values {
            if let f = v.link.sample(at: now), f.queue > feedback?.queue ?? -1 { feedback = f }
        }
        var backlog = 0
        var slowest = Duration.zero
        for (id, var v) in viewers {
            if feedback == nil {
                backlog = max(backlog, v.pending)
                slowest = max(slowest, v.slowestSend, v.waiting.first.map { now - $0 } ?? .zero)
            }
            v.slowestSend = .zero
            viewers[id] = v
        }
        return LinkSample(backlog: backlog, slowestSend: slowest, feedback: feedback)
    }
}
