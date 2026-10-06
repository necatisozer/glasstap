import Foundation

/// Who gets which stream message. Pure state, so that the rules are testable
/// without a network; `ViewerHub` applies the results to real connections.
public struct ViewerState<ID: Hashable & Sendable>: Sendable {
    /// A viewer more than this many messages behind skips to the next key frame.
    public static var maxPending: Int { 15 }
    /// A viewer that skipped takes a key frame again only when its backlog is this short.
    /// The gap to `maxPending` keeps a link at its limit from getting a key frame every few sends.
    public static var resumePending: Int { maxPending / 2 }

    struct Viewer: Sendable {
        var needKey = true
        var pending = 0
    }

    private var viewers: [ID: Viewer] = [:]
    /// The framed config message of the current stream.
    private var config: Data?
    /// True while some viewer waits for a key frame and can take one. Only a key frame clears it.
    public private(set) var wantKeyFrame = true

    public init() {}

    public var count: Int { viewers.count }
    func contains(_ id: ID) -> Bool { viewers[id] != nil }

    /// Adds a viewer and returns the viewers that it replaces. Keep only the newest
    /// viewer: viewers can share one tunnel, so one that stops reading would stall the others.
    public mutating func join(_ id: ID) -> [ID] {
        let old = viewers.keys.filter { $0 != id }
        viewers = [id: Viewer()]
        wantKeyFrame = true
        return old
    }

    @discardableResult
    public mutating func leave(_ id: ID) -> Bool {
        viewers.removeValue(forKey: id) != nil
    }

    /// A send to the viewer has completed.
    public mutating func sent(_ id: ID) {
        guard var v = viewers[id] else { return }
        v.pending -= 1
        viewers[id] = v
        // A viewer that waited for its backlog to drain can take a key frame now.
        if v.needKey && v.pending <= Self.resumePending { wantKeyFrame = true }
    }

    /// Distributes one framed frame message. `config` comes with each key frame and is
    /// stored before the frame goes out. Returns the messages for each viewer, in order.
    public mutating func frame(_ message: Data, key: Bool, config newConfig: StreamConfig? = nil) -> [(id: ID, messages: [Data])] {
        if key, let newConfig {
            let message = StreamMessage.encode(.config, newConfig.json)
            // A new codec or size needs a decoder reset, so every viewer starts again from a key frame.
            if message != config {
                config = message
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
                messages.append(config)
            }
            messages.append(message)
            v.pending += messages.count
            viewers[id] = v
            out.append((id, messages))
        }
        // The request stays until a key frame reaches every viewer that can take one.
        // A frame that the encoder drops therefore leaves it in place.
        if key { wantKeyFrame = viewers.values.contains { $0.needKey && $0.pending <= Self.resumePending } }
        return out
    }
}
