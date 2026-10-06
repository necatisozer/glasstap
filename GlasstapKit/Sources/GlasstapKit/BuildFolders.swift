import Foundation

/// Lets jobs with the same key run one at a time, in the order that they arrive. A job that
/// waits and is cancelled leaves the queue at once, so it never waits behind a long build.
actor SerialGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var busy: Set<String> = []
    private var waiters: [String: [Waiter]] = [:]

    func serialize<T: Sendable>(_ key: String, _ job: @Sendable () async throws -> T) async throws -> T {
        try await lock(key)
        do {
            let value = try await job()
            unlock(key)
            return value
        } catch {
            unlock(key)
            throw error
        }
    }

    private func lock(_ key: String) async throws {
        try Task.checkCancellation()
        if !busy.contains(key) {
            busy.insert(key)
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waiters[key, default: []].append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            // The handler runs outside the actor. Its task runs after the append above.
            Task { await self.cancel(id, key: key) }
        }
    }

    private func cancel(_ id: UUID, key: String) {
        guard let index = waiters[key]?.firstIndex(where: { $0.id == id }) else { return }
        waiters[key]!.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// Hands the key to the next waiter, or frees it.
    private func unlock(_ key: String) {
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[key] = queue
            next.continuation.resume()
        } else {
            busy.remove(key)
            waiters[key] = nil
        }
    }
}

/// The WDA build folders. Two iPhones on the same iOS major version share one build: the first
/// builds it, and the second uses it. A signing failure needs a clean build, but the folder may
/// hold the test run of another iPhone. Then the clean build goes into a new folder, and the old
/// one goes when its last test run ends.
actor BuildFolders {
    private let root: URL
    private let findTestRun: @Sendable (URL) -> URL?
    private let removeFolder: @Sendable (URL) -> Void
    private let gate = SerialGate()
    /// The folder of each build key, when it is not `<root>/<key>`.
    private var current: [String: URL] = [:]
    /// The test runs that use each folder now.
    private var users: [URL: Int] = [:]
    /// Folders that no new start uses, to delete when their last test run ends.
    private var retired: Set<URL> = []
    /// The folder of each test run that this actor handed out.
    private var folderOfTestRun: [URL: URL] = [:]

    init(root: URL, findTestRun: @escaping @Sendable (URL) -> URL? = { WDABuild.findTestRun(inDerivedData: $0) },
         removeFolder: @escaping @Sendable (URL) -> Void = { try? FileManager.default.removeItem(at: $0) }) {
        self.root = root
        self.findTestRun = findTestRun
        self.removeFolder = removeFolder
    }

    /// Always with a directory hint: URL equality would otherwise depend on whether the folder exists yet.
    func folder(for key: String) -> URL {
        current[key] ?? root.appending(path: key, directoryHint: .isDirectory)
    }

    func cachedTestRun(key: String) -> URL? {
        let folder = folder(for: key)
        return findTestRun(folder).map { record($0, in: folder) }
    }

    /// Remembers the folder of a test run, for `acquire`.
    private func record(_ testRun: URL, in folder: URL) -> URL {
        folderOfTestRun[testRun] = folder
        return testRun
    }

    /// Returns the test run of `key`. If an earlier build made one while this call waited, the
    /// call uses it. Otherwise `run` builds into the folder and returns its test run.
    func build(key: String, _ run: @escaping @Sendable (URL) async throws -> URL) async throws -> URL {
        try await gate.serialize(key) {
            let folder = await self.folder(for: key)
            var testRun = self.findTestRun(folder)
            if testRun == nil { testRun = try await run(folder) }
            return await self.record(testRun!, in: folder)
        }
    }

    /// Makes the next build of `key` a clean one. A folder that no test run uses is deleted.
    /// A folder in use stays until its last test run ends, and the next build goes into a new folder.
    func removeBuild(key: String) async throws {
        try await gate.serialize(key) { await self.retire(key: key) }
    }

    private func retire(key: String) {
        let folder = folder(for: key)
        if users[folder, default: 0] == 0 {
            removeFolder(folder)
        } else {
            retired.insert(folder)
            current[key] = root.appending(path: "\(key)-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        }
    }

    /// A test run starts from `testRun`, which `build` or `cachedTestRun` returned. Returns the
    /// folder to pass to `release`, or nil for a test run that this actor does not know.
    func acquire(testRun: URL) -> URL? {
        guard let folder = folderOfTestRun[testRun] else { return nil }
        users[folder, default: 0] += 1
        return folder
    }

    /// A test run from `folder` has ended.
    func release(_ folder: URL) {
        let left = users[folder, default: 1] - 1
        users[folder] = left > 0 ? left : nil
        if left <= 0, retired.remove(folder) != nil { removeFolder(folder) }
    }

}
