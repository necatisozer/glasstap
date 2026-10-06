import Foundation

/// Adapts the encoder to the link of the viewer. Pure state: the caller passes the time
/// and the link measurements at each tick, so the rules are testable with a fake clock.
///
/// A fresh report from the viewer decides, because only the viewer sees every buffer on the way.
/// Without one, the host's own backlog and send times decide. They see congestion only once
/// the buffers between the host and the viewer are full.
public struct BitrateController: Sendable, Equatable {
    /// Floors of the queue thresholds, in bytes. At a low bitrate, a fraction of a second is
    /// only a few KB, less than the normal jitter of the stream.
    public static let congestedFloor = 64 * 1024
    public static let growingFloor = 32 * 1024
    public static let clearFloor = 16 * 1024
    /// Growth over one second must be more than this, and more than 0.15 s of the rate, to count.
    public static let growthFloor = 16 * 1024
    /// More messages than this waiting for the viewer means congestion.
    public static let maxBacklog = 5
    /// A send slower than this, from enqueue to completion, means congestion.
    public static let slowSend: Duration = .milliseconds(300)
    public static let decreaseFactor = 0.7
    public static let increaseFactor = 1.1
    /// The link must be clear this long before the bitrate rises.
    public static let clearPeriod: Duration = .seconds(2)
    /// No second decrease this soon after one. The backlog of one burst takes time to drain,
    /// and it would otherwise cut the bitrate again for the same congestion.
    public static let hold: Duration = .seconds(1)

    /// One size of the stream, with the lowest bitrate at which the encoder still sends most frames.
    public struct Rung: Sendable, Equatable {
        public let width: Int
        /// Bits per second.
        public let floor: Int
        /// Seconds between key frames. At the smallest size a longer interval leaves more bits for the frames between.
        public let keyFrameInterval: Int
    }

    /// The sizes, from the settings' width down. Under a rung's floor, VideoToolbox drops most frames:
    /// on scrolling text at 590 px, 250 kbit/s sent 206 of 240 frames, but 200 kbit/s only 12.
    /// So a congested link at the floor gets a smaller picture, not a lower bitrate. Measured at 590 px wide:
    /// 590 px from 250 kbit/s, 392 px from 150 kbit/s, 294 px from 75 kbit/s with a key frame every 4 s
    /// (136 of 240 frames; 20 with one every 2 s). Other widths scale the floors with the area.
    public static func ladder(width: Int) -> [Rung] {
        let full = width / 2 * 2
        let area = Double(full * full) / Double(590 * 590)
        func floor(_ measured: Int) -> Int { Int((Double(measured) * area / 1000).rounded()) * 1000 }
        return [
            Rung(width: full, floor: floor(250_000), keyFrameInterval: 2),
            Rung(width: full * 2 / 3 / 2 * 2, floor: floor(150_000), keyFrameInterval: 2),
            Rung(width: full / 2 / 2 * 2, floor: floor(75_000), keyFrameInterval: 4),
        ]
    }

    public enum Reason: Sendable, Equatable, CustomStringConvertible {
        case congested(backlog: Int, slowestSend: Duration)
        case queued(bytes: Int, growing: Bool)
        case clear
        case noViewer
        case newViewer

        public var description: String {
            switch self {
            case let .congested(backlog, slowest):
                "congested: \(backlog) messages waiting, slowest send \(slowest.milliseconds) ms"
            case let .queued(bytes, growing):
                "congested: \(bytes / 1000) KB queued for the viewer\(growing ? " and growing" : "")"
            case .clear: "link clear for \(BitrateController.clearPeriod.milliseconds) ms"
            case .noViewer: "no viewer"
            case .newViewer: "new viewer"
            }
        }
    }

    public struct Change: Sendable, Equatable {
        public let target: StreamStats
        public let size: Rung
        public let reason: Reason
    }

    /// The settings. The controller never goes above them.
    public let configured: StreamStats
    public let ladder: [Rung]
    public private(set) var target: StreamStats
    public private(set) var rung = 0
    private var lastDecrease: Duration?
    private var clearSince: Duration?

    /// `width` is the width in the settings.
    public init(configured: StreamStats, width: Int = 590) {
        self.configured = configured
        ladder = Self.ladder(width: width)
        target = configured
    }

    public var size: Rung { ladder[rung] }

    /// The floor of a rung. A configured bitrate below it is its own floor.
    private func floor(_ rung: Int) -> Int { min(ladder[rung].floor, configured.bitrate) }

    private enum Assessment {
        case congested(Reason)
        case clear
        /// Neither: the bitrate stays, and the clear period starts again.
        case unsure
    }

    /// The bytes that the target bitrate carries in `seconds`.
    private func bytes(in seconds: Double) -> Int {
        Int(Double(target.bitrate) / 8 * seconds)
    }

    private func assess(_ link: LinkSample) -> Assessment {
        if let f = link.feedback {
            // Each threshold leaves room for one key frame, which goes out at once.
            let growing = f.growth > max(Self.growthFloor, bytes(in: 0.15))
                && f.queue > max(Self.growingFloor, f.keyFrame + bytes(in: 0.5))
            if f.queue > max(Self.congestedFloor, f.keyFrame + bytes(in: 1)) || growing {
                // A queue that shrinks drains by itself. A cut now would go below what the link carries.
                guard f.growth >= 0 else { return .unsure }
                return .congested(.queued(bytes: f.queue, growing: growing))
            }
            return f.queue < max(Self.clearFloor, f.keyFrame + bytes(in: 0.25)) ? .clear : .unsure
        }
        if link.backlog > Self.maxBacklog || link.slowestSend > Self.slowSend {
            return .congested(.congested(backlog: link.backlog, slowestSend: link.slowestSend))
        }
        return .clear
    }

    /// One measurement of the link, every 250 ms or so.
    public mutating func tick(_ link: LinkSample, now: Duration) -> Change? {
        switch assess(link) {
        case let .congested(reason):
            clearSince = nil
            if let lastDecrease, now - lastDecrease < Self.hold { return nil }
            var next = target
            var nextRung = rung
            let cut = Int((Double(target.bitrate) * Self.decreaseFactor).rounded())
            if target.bitrate > floor(rung) {
                next.bitrate = max(floor(rung), cut)
            } else if rung + 1 < ladder.count {
                // At this size's floor: a smaller picture can go lower without starving the frames.
                nextRung += 1
                next.bitrate = max(floor(nextRung), cut)
            }
            guard next != target || nextRung != rung else { return nil }
            lastDecrease = now
            return change(to: next, rung: nextRung, reason)
        case .unsure:
            clearSince = nil
            return nil
        case .clear:
            break
        }
        guard let since = clearSince else {
            clearSince = now
            return nil
        }
        guard now - since >= Self.clearPeriod else { return nil }
        // The next raise needs another clear period.
        clearSince = now
        var next = target
        var nextRung = rung
        // The larger size comes back once the bitrate reaches its floor. Sooner, it would starve the frames.
        if rung > 0, target.bitrate >= floor(rung - 1) {
            nextRung -= 1
        } else {
            next.bitrate = min(configured.bitrate, Int((Double(target.bitrate) * Self.increaseFactor).rounded()))
        }
        guard next != target || nextRung != rung else { return nil }
        return change(to: next, rung: nextRung, .clear)
    }

    /// Back to the settings: when no viewer is left, or a new one joins. Another viewer may have another link.
    public mutating func reset(_ reason: Reason = .noViewer) -> Change? {
        lastDecrease = nil
        clearSince = nil
        guard target != configured || rung != 0 else { return nil }
        return change(to: configured, rung: 0, reason)
    }

    private mutating func change(to next: StreamStats, rung nextRung: Int, _ reason: Reason) -> Change {
        target = next
        rung = nextRung
        return Change(target: next, size: ladder[nextRung], reason: reason)
    }
}

extension Duration {
    var milliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }
}
