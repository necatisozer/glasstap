import Foundation
import os

/// The real side effects of the WDA manager: the download, xcodebuild, devicectl and HTTP.
public struct SystemWDAHost: WDAHost {
    public let root: URL
    public let source: WDASource
    /// Shared by every iPhone, because the app passes one host to all sessions.
    let folders: BuildFolders

    public init(root: URL = GlasstapFolder.url, source: WDASource = .pinned) {
        self.root = root
        self.source = source
        folders = BuildFolders(root: root.appendingPathComponent("wda-build"))
    }

    /// A build that runs longer than this has hung.
    static let buildTimeout: Duration = .seconds(30 * 60)

    /// xcodebuild buffers its output when it writes to a pipe. This makes it write each line at once,
    /// so that `ServerURLHere` arrives when WDA prints it.
    static let environment = ["NSUnbufferedIO": "YES"]

    public var wdaVersion: String { source.version }

    public func installedSource() -> URL? {
        source.installed(in: root)
    }

    public func downloadSource() async throws -> URL {
        try GlasstapFolder.ensurePrivate(root)
        return try await source.install(in: root)
    }

    public func deviceDetails(udid: String) async throws -> CoreDevice {
        try await Devicectl.details(udid: udid)
    }

    public func cachedTestRun(for build: WDABuild) async -> URL? {
        await folders.cachedTestRun(key: build.cacheKey)
    }

    /// Two iPhones with the same iOS major version share the build folder, and two xcodebuild runs
    /// in one folder conflict. The second build waits for the first, and then uses its result.
    public func build(_ build: WDABuild, source: URL, udid: String) async throws -> URL {
        try await folders.build(key: build.cacheKey) { folder in
            try await runBuild(build, source: source, udid: udid, folder: folder)
        }
    }

    private func runBuild(_ build: WDABuild, source: URL, udid: String, folder: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let xcconfig = folder.appendingPathComponent("glasstap-signing.xcconfig")
        try Data(build.xcconfig.utf8).write(to: xcconfig, options: .atomic)
        let arguments = build.buildArguments(project: source.appendingPathComponent("WebDriverAgent.xcodeproj"),
                                             udid: udid, derivedData: folder, xcconfig: xcconfig)
        var scan = XcodebuildScan(keepLines: WDAManager.keptLines)
        let result = try await ChildProcess.run("/usr/bin/xcodebuild", arguments, environment: Self.environment,
                                                keepLines: 0, timeout: Self.buildTimeout) { scan.consume($0) }
        guard result.status == 0, let testRun = WDABuild.findTestRun(inDerivedData: folder) else {
            throw WDABuildFailure(kind: scan.failureKind, lines: scan.lines)
        }
        return testRun
    }

    public func removeBuild(_ build: WDABuild) async throws {
        try await folders.removeBuild(key: build.cacheKey)
    }

    public func launch(testRun: URL, udid: String) async throws -> any WDAProcess {
        let pidFile = TestRunPidFile(root: root, udid: udid)
        // Two test runs on one device conflict. A crashed app leaves its run behind.
        await pidFile.stopStaleRun()
        // The folder stays while this run uses it, also if another iPhone needs a clean build.
        let folder = await folders.acquire(testRun: testRun)
        let child: ChildProcess
        do {
            child = try ChildProcess("/usr/bin/xcodebuild", WDABuild.testArguments(testRun: testRun, udid: udid),
                                     environment: Self.environment)
        } catch {
            if let folder { await folders.release(folder) }
            throw error
        }
        pidFile.write(child.pid)
        return PidFileProcess(child: child, pidFile: pidFile, folder: folder, folders: folders)
    }

    public func isHealthy(_ baseURL: URL) async -> Bool {
        await WDAClient.isReachable(baseURL)
    }
}

/// A test run whose pid file goes away when the run ends.
struct PidFileProcess: WDAProcess {
    let child: ChildProcess
    let pidFile: TestRunPidFile
    let folder: URL?
    let folders: BuildFolders
    /// A second terminate must not release the folder twice.
    private let released = OSAllocatedUnfairLock(initialState: false)

    init(child: ChildProcess, pidFile: TestRunPidFile, folder: URL?, folders: BuildFolders) {
        self.child = child
        self.pidFile = pidFile
        self.folder = folder
        self.folders = folders
    }

    var lines: AsyncStream<String> { child.lines }

    func exitStatus() async -> Int32 {
        await child.exitStatus()
    }

    func terminate() async {
        await child.terminate()
        pidFile.remove(ifHolding: child.pid)
        let first = released.withLock { done in
            defer { done = true }
            return !done
        }
        if first, let folder { await folders.release(folder) }
    }
}
