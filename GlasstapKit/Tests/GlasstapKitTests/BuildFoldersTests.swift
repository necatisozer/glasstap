import Foundation
import os
import Testing
@testable import GlasstapKit

@Suite struct SerialGateTests {
    /// A job that holds the gate until `open()`.
    final class Latch: @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (entered: false, continuation: CheckedContinuation<Void, Never>?.none))
        var entered: Bool { state.withLock { $0.entered } }

        func wait() async {
            await withCheckedContinuation { c in state.withLock { $0 = (true, c) } }
        }

        func open() {
            state.withLock { s in
                s.continuation?.resume()
                s.continuation = nil
            }
        }
    }

    @Test func aCancelledWaiterLeavesAtOnce() async throws {
        let gate = SerialGate()
        let latch = Latch()
        let first = Task { try await gate.serialize("k") { await latch.wait(); return 1 } }
        #expect(await eventually { latch.entered })
        let second = Task { try await gate.serialize("k") { 2 } }
        try await Task.sleep(for: .milliseconds(50))
        let cancelledAt = ContinuousClock.now
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        // It did not wait for the first job, which still holds the gate.
        #expect(ContinuousClock.now - cancelledAt < .milliseconds(500))
        let third = Task { try await gate.serialize("k") { 3 } }
        latch.open()
        #expect(try await first.value == 1)
        #expect(try await third.value == 3)
    }

    @Test func jobsRunInOrderAndOtherKeysDoNotWait() async throws {
        let gate = SerialGate()
        let latch = Latch()
        let order = OSAllocatedUnfairLock(initialState: [String]())
        let holder = Task { try await gate.serialize("k") { await latch.wait(); order.withLock { $0.append("a") } } }
        #expect(await eventually { latch.entered })
        let b = Task { try await gate.serialize("k") { order.withLock { $0.append("b") } } }
        try await Task.sleep(for: .milliseconds(20))
        let c = Task { try await gate.serialize("k") { order.withLock { $0.append("c") } } }
        try await Task.sleep(for: .milliseconds(20))
        // Another key runs while "k" is held.
        try await gate.serialize("other") { order.withLock { $0.append("other") } }
        latch.open()
        try await holder.value
        try await b.value
        try await c.value
        #expect(order.withLock { $0 } == ["other", "a", "b", "c"])
    }

    @Test func aFailedJobFreesTheGate() async throws {
        struct Boom: Error {}
        let gate = SerialGate()
        await #expect(throws: Boom.self) { try await gate.serialize("k") { throw Boom() } }
        #expect(try await gate.serialize("k") { 1 } == 1)
    }
}

@Suite struct BuildFoldersTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("glasstap-builds-\(UUID().uuidString)")

    /// What xcodebuild leaves in a build folder.
    @Sendable static func makeTestRun(in folder: URL) throws -> URL {
        let products = folder.appendingPathComponent("Build/Products")
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        let file = products.appendingPathComponent("WebDriverAgentRunner_iphoneos26.0-arm64.xctestrun")
        try Data().write(to: file)
        return file
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test func aSecondIPhoneUsesTheBuildOfTheFirst() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = BuildFolders(root: root)
        let builds = OSAllocatedUnfairLock(initialState: 0)
        let run: @Sendable (URL) async throws -> URL = { folder in
            builds.withLock { $0 += 1 }
            try await Task.sleep(for: .milliseconds(100))
            return try Self.makeTestRun(in: folder)
        }
        // Both found no cached build, as two managers do when two iPhones come at once.
        async let first = folders.build(key: "k", run)
        async let second = folders.build(key: "k", run)
        let (a, b) = try await (first, second)
        #expect(a == b)
        #expect(builds.withLock { $0 } == 1)
        #expect(await folders.cachedTestRun(key: "k") == a)
    }

    @Test func aCleanBuildDeletesAFolderThatNoRunUses() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = BuildFolders(root: root)
        let testRun = try await folders.build(key: "k") { try Self.makeTestRun(in: $0) }
        let folder = root.appending(path: "k", directoryHint: .isDirectory)
        try await folders.removeBuild(key: "k")
        #expect(!exists(folder))
        #expect(await folders.cachedTestRun(key: "k") == nil)
        // The clean build goes into the same folder again.
        #expect(try await folders.build(key: "k") { try Self.makeTestRun(in: $0) } == testRun)
    }

    @Test func aFolderInUseStaysUntilItsLastRunEnds() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = BuildFolders(root: root)
        let old = try await folders.build(key: "k") { try Self.makeTestRun(in: $0) }
        let oldFolder = root.appending(path: "k", directoryHint: .isDirectory)
        // iPhone A runs WDA from the folder. iPhone B needs a clean build after a signing failure.
        let used = try #require(await folders.acquire(testRun: old))
        #expect(used == oldFolder)
        try await folders.removeBuild(key: "k")
        #expect(exists(old))
        let newFolder = await folders.folder(for: "k")
        #expect(newFolder != oldFolder)
        #expect(await folders.cachedTestRun(key: "k") == nil)
        let fresh = try await folders.build(key: "k") { try Self.makeTestRun(in: $0) }
        #expect(fresh.path.hasPrefix(newFolder.path))
        // A's run ends: the old folder goes, the new one stays.
        await folders.release(used)
        #expect(!exists(oldFolder))
        #expect(exists(fresh))
    }

    @Test func aCleanBuildWaitsForARunningBuild() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let events = OSAllocatedUnfairLock(initialState: [String]())
        let folders = BuildFolders(root: root, removeFolder: { folder in
            events.withLock { $0.append("remove") }
            try? FileManager.default.removeItem(at: folder)
        })
        let latch = SerialGateTests.Latch()
        let building = Task {
            try await folders.build(key: "k") { folder in
                await latch.wait()
                events.withLock { $0.append("built") }
                return try Self.makeTestRun(in: folder)
            }
        }
        #expect(await eventually { latch.entered })
        let removing = Task { try await folders.removeBuild(key: "k") }
        try await Task.sleep(for: .milliseconds(50))
        #expect(events.withLock { $0 }.isEmpty)
        latch.open()
        _ = try await building.value
        try await removing.value
        #expect(events.withLock { $0 } == ["built", "remove"])
    }

    @Test func aCancelledBuildDoesNotWaitForAnotherIPhonesBuild() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = BuildFolders(root: root)
        let latch = SerialGateTests.Latch()
        let first = Task { try await folders.build(key: "k") { folder in await latch.wait(); return try Self.makeTestRun(in: folder) } }
        #expect(await eventually { latch.entered })
        let ran = OSAllocatedUnfairLock(initialState: false)
        let second = Task { try await folders.build(key: "k") { folder in ran.withLock { $0 = true }; return folder } }
        try await Task.sleep(for: .milliseconds(50))
        let cancelledAt = ContinuousClock.now
        // B is unplugged while A builds.
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(ContinuousClock.now - cancelledAt < .milliseconds(500))
        latch.open()
        _ = try await first.value
        #expect(!ran.withLock { $0 })
    }

    @Test func onlyAKnownRunIsCounted() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = BuildFolders(root: root)
        #expect(await folders.acquire(testRun: root.appendingPathComponent("k/Build/Products/x.xctestrun")) == nil)
        let testRun = try await folders.build(key: "k") { try Self.makeTestRun(in: $0) }
        #expect(await folders.acquire(testRun: testRun) == root.appending(path: "k", directoryHint: .isDirectory))
        // A build of an earlier launch is known once the cache lookup has returned it.
        let other = try Self.makeTestRun(in: root.appending(path: "j", directoryHint: .isDirectory))
        #expect(await folders.acquire(testRun: other) == nil)
        #expect(await folders.cachedTestRun(key: "j") == other)
        #expect(await folders.acquire(testRun: other) == root.appending(path: "j", directoryHint: .isDirectory))
    }
}
