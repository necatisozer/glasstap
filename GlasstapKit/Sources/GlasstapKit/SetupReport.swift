import Foundation

/// A check of the Setup window that fails. Equal values are the same problem, so a problem that
/// stays does not open the window again, and a new reason does.
public enum SetupProblem: Hashable, Sendable {
    case xcode
    case teamID
    case iPhone(DeviceProblem)
    case camera
    case wda(String)
}

public enum SetupReport {
    /// The failing checks, in the order of the Setup window. The menu and the window read the same list.
    public static func problems(xcode: XcodeStatus?, settings: GlasstapSettings, identity: DeviceIdentity,
                                now: Duration, cameraDenied: Bool, wda: WDAState) -> [SetupProblem] {
        var problems: [SetupProblem] = []
        if let xcode, !xcode.isReady { problems.append(.xcode) }
        // The user's own WDA needs no team.
        if settings.teamID.isEmpty && settings.wdaURLOverride == nil { problems.append(.teamID) }
        // A freshly plugged iPhone looks unpaired until its tunnel is up, so only a lasting problem counts.
        if let problem = identity.lastingProblem(at: now) { problems.append(.iPhone(problem)) }
        if cameraDenied { problems.append(.camera) }
        if case let .failed(reason) = wda { problems.append(.wda(reason)) }
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
