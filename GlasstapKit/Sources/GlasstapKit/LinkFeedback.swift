import Foundation

/// What a viewer reports about one stream: the bytes it has received. The host counts the bytes
/// it handed to the connection, so the difference is the stream still on the way. That includes
/// every buffer between the two, such as an SSH channel, which the host cannot see by itself.
///
/// Part of that is the pipe itself: about two round trips of stream, because a report is
/// one round trip old when it arrives. The lowest amount in flight over the last 10 s is that
/// baseline. Only what is above it is a queue.
struct LinkFeedback: Sendable {
    /// A report older than this means that the viewer gives no feedback now.
    static let fresh: Duration = .seconds(1)
    /// Growth counts against the newest report at least this much older.
    static let growthWindow: Duration = .seconds(1)
    /// The baseline is the lowest amount in flight in this window. The window lets the baseline
    /// rise again when the path gets longer, for example when the viewer moves to another network.
    static let baselineWindow: Duration = .seconds(10)

    private(set) var sent = 0
    /// The reports of the baseline window, oldest first: the time and the bytes in flight at that time.
    private var reports: [(at: Duration, inFlight: Int)] = []
    /// The key frames of the baseline window: the time and the size of each.
    private var keyFrames: [(at: Duration, bytes: Int)] = []

    mutating func add(sent bytes: Int) {
        sent += bytes
    }

    mutating func add(keyFrame bytes: Int, at now: Duration) {
        keyFrames.append((now, bytes))
        keyFrames.removeAll { now - $0.at > Self.baselineWindow }
    }

    mutating func report(received: Int, at now: Duration) {
        reports.append((now, max(0, sent - received)))
        reports.removeAll { now - $0.at > Self.baselineWindow }
    }

    /// nil when no report is fresh.
    func sample(at now: Duration) -> ViewerFeedback? {
        guard let last = reports.last, now - last.at <= Self.fresh else { return nil }
        var baseline = last.inFlight
        // The newest report that is a whole growth window older than the last one.
        var base: Int?
        for r in reports {
            baseline = min(baseline, r.inFlight)
            if last.at - r.at >= Self.growthWindow { base = r.inFlight }
        }
        var keyFrame = 0
        for k in keyFrames { keyFrame = max(keyFrame, k.bytes) }
        return ViewerFeedback(queue: last.inFlight - baseline, growth: base.map { last.inFlight - $0 } ?? 0,
                              keyFrame: keyFrame)
    }
}

/// The latest fresh report of a viewer.
public struct ViewerFeedback: Sendable, Equatable {
    /// The bytes in flight above the baseline of the pipe.
    public let queue: Int
    /// How much the bytes in flight grew over the last second. Negative when they fell.
    public let growth: Int
    /// The largest key frame of the last 10 s. One key frame in flight is the normal shape of
    /// the stream, so the thresholds leave room for it.
    public let keyFrame: Int

    public init(queue: Int, growth: Int, keyFrame: Int = 0) {
        self.queue = queue
        self.growth = growth
        self.keyFrame = keyFrame
    }
}

/// One measurement of the link to the viewer, for `BitrateController`.
public struct LinkSample: Sendable, Equatable {
    /// The messages that wait to be sent.
    public let backlog: Int
    /// The slowest send since the last sample.
    public let slowestSend: Duration
    /// The viewer's own report, when one is fresh. Old pages send none.
    public let feedback: ViewerFeedback?

    public init(backlog: Int, slowestSend: Duration, feedback: ViewerFeedback? = nil) {
        self.backlog = backlog
        self.slowestSend = slowestSend
        self.feedback = feedback
    }
}
