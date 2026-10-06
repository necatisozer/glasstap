import Darwin
import Foundation
import os

/// The pid of the test run on one iPhone. If the app crashes, its test run stays alive and keeps
/// the iPhone busy. The next start reads the file and stops that run first.
public struct TestRunPidFile: Sendable {
    public let file: URL
    public let udid: String
    private let log = Logger(subsystem: "io.github.necatisozer.glasstap", category: "wda")

    /// `<root>/wda-<udid>.pid`
    public init(root: URL, udid: String) {
        self.udid = udid
        file = root.appendingPathComponent("wda-\(udid).pid")
    }

    public func read() -> pid_t? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0 > 1 ? $0 : nil }
    }

    /// The file is a safety net, so a failure to write it only goes to the log.
    public func write(_ pid: pid_t) {
        do {
            try GlasstapFolder.ensurePrivate(file.deletingLastPathComponent())
            try Data("\(pid)\n".utf8).write(to: file, options: .atomic)
        } catch {
            log.error("pid file: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes the file, unless a newer run has written its own pid in it.
    public func remove(ifHolding pid: pid_t) {
        guard read() == pid else { return }
        try? FileManager.default.removeItem(at: file)
    }

    /// Stops the test run that the file names. A pid can be reused by an unrelated process, so the
    /// run is stopped only if its command line is still `xcodebuild test-without-building` for this
    /// iPhone and it still leads its own process group. Returns true if it stopped one.
    @discardableResult
    public func stopStaleRun(grace: Duration = .seconds(5)) async -> Bool {
        guard let pid = read() else { return false }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let arguments = Self.arguments(of: pid), Self.isTestRun(arguments, udid: udid), getpgid(pid) == pid else {
            return false
        }
        log.notice("Stopping the test run \(pid) that an earlier launch left behind.")
        // This app is not the parent, so it cannot wait for the leader's exit. It polls the group.
        await ChildProcess.stopGroup(pid, grace: grace)
        return true
    }

    static func isTestRun(_ arguments: [String], udid: String) -> Bool {
        guard let program = arguments.first, URL(fileURLWithPath: program).lastPathComponent == "xcodebuild" else {
            return false
        }
        return arguments.contains("test-without-building") && arguments.contains("id=\(udid)")
    }

    /// The command line of a process of this user, from KERN_PROCARGS2. nil if it is gone or not ours.
    static func arguments(of pid: pid_t) -> [String]? {
        var argMax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var argMaxMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argMaxMIB, 2, &argMax, &size, nil, 0) == 0, argMax > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(argMax))
        size = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        // Layout: argc, the executable path, padding NULs, then argc NUL-terminated arguments.
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}
