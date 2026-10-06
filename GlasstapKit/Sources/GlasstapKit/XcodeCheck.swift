import Foundation

/// Whether the selected developer folder is a full Xcode. glasstap needs devicectl and
/// xcodebuild, and the Command Line Tools alone have neither.
public enum XcodeStatus: Sendable, Equatable {
    case ready(developerDir: String)
    case commandLineToolsOnly(developerDir: String)
    case noDevicectl(developerDir: String)
    case notFound

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// `developerDir` is the output of `xcode-select -p`, or nil if it failed.
    public static func evaluate(developerDir: String?, devicectlFound: Bool) -> XcodeStatus {
        guard let dir = developerDir?.trimmingCharacters(in: .whitespacesAndNewlines), !dir.isEmpty else { return .notFound }
        guard dir.contains(".app/Contents/Developer") else { return .commandLineToolsOnly(developerDir: dir) }
        return devicectlFound ? .ready(developerDir: dir) : .noDevicectl(developerDir: dir)
    }

    public static func check() async -> XcodeStatus {
        let select = try? await ChildProcess.run("/usr/bin/xcode-select", ["-p"], keepLines: 5, timeout: .seconds(30))
        let dir = select.flatMap { $0.status == 0 ? $0.lines.first : nil }
        // xcrun finds devicectl in the developer folder, so a file check gives the same answer with no second process.
        let devicectl = dir.map { URL(fileURLWithPath: $0).appendingPathComponent("usr/bin/devicectl").path }
        return evaluate(developerDir: dir, devicectlFound: devicectl.map { FileManager.default.isExecutableFile(atPath: $0) } ?? false)
    }
}
