import Foundation

/// A check of the Setup window that fails. Equal values are the same problem, so a problem that
/// stays does not open the window again, and a new reason does. The problems of an iPhone carry
/// its capture id, so that two iPhones with the same problem stay two problems.
public enum SetupProblem: Hashable, Sendable {
    case xcode
    case teamID
    case iPhone(device: String, DeviceProblem)
    case camera
    case wda(device: String, String)
}

public enum SetupReport {
    /// What the report needs of one iPhone.
    public struct Device: Sendable {
        /// The capture id.
        public var id: String
        public var identity: DeviceIdentity
        /// The `now` of the clock that recorded `identity`.
        public var now: Duration
        public var wda: WDAState

        public init(id: String, identity: DeviceIdentity, now: Duration, wda: WDAState) {
            self.id = id
            self.identity = identity
            self.now = now
            self.wda = wda
        }
    }

    /// The failing checks, in the order of the Setup window. The menu and the window read the same list.
    public static func problems(xcode: XcodeStatus?, settings: GlasstapSettings, devices: [Device],
                                cameraDenied: Bool) -> [SetupProblem] {
        var problems: [SetupProblem] = []
        if let xcode, !xcode.isReady { problems.append(.xcode) }
        // The user's own WDA needs no team.
        if settings.teamID.isEmpty && settings.wdaURLOverride == nil { problems.append(.teamID) }
        // A freshly plugged iPhone looks unpaired until its tunnel is up, so only a lasting problem counts.
        for device in devices {
            if let problem = device.identity.lastingProblem(at: device.now) { problems.append(.iPhone(device: device.id, problem)) }
        }
        if cameraDenied { problems.append(.camera) }
        for device in devices {
            if case let .failed(reason) = device.wda { problems.append(.wda(device: device.id, reason)) }
        }
        return problems
    }
}

/// Remembers which problems the user has seen, so that only a new one opens the Setup window.
public struct SetupProblemTracker: Sendable {
    private var shown: Set<SetupProblem> = []

    public init() {}

    /// The problems that were not there at the last call. A problem that went away can come back as new.
    public mutating func newProblems(in current: [SetupProblem]) -> [SetupProblem] {
        let new = current.filter { !shown.contains($0) }
        shown = Set(current)
        return new
    }
}
