import Darwin
import Foundation
import Testing
@testable import GlasstapKit

@Suite struct TestRunPidFileTests {
    let udid = "00008101-000A1B2C3D4E5F60"

    func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("glasstap-tests-\(UUID().uuidString)")
    }

    @Test func onlyATestRunForThisIPhoneCounts() {
        let run = ["/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild", "test-without-building",
                   "-xctestrun", "/x.xctestrun", "-destination", "id=\(udid)"]
        #expect(TestRunPidFile.isTestRun(run, udid: udid))
        #expect(!TestRunPidFile.isTestRun(run, udid: "OTHER"))
        #expect(!TestRunPidFile.isTestRun(["/usr/bin/xcodebuild", "build-for-testing", "-destination", "id=\(udid)"], udid: udid))
        #expect(!TestRunPidFile.isTestRun(["/bin/sleep", "test-without-building", "id=\(udid)"], udid: udid))
        #expect(!TestRunPidFile.isTestRun([], udid: udid))
    }

    @Test func readsTheCommandLineOfAProcess() async throws {
        let child = try ChildProcess("/bin/sleep", ["30"])
        // The command line is in place once the exec has happened.
        #expect(await eventually { TestRunPidFile.arguments(of: child.pid) == ["/bin/sleep", "30"] })
        await child.terminate(grace: .milliseconds(300))
        #expect(TestRunPidFile.arguments(of: child.pid) == nil)
    }

    @Test func writeReadAndRemove() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = TestRunPidFile(root: root, udid: udid)
        #expect(file.file.lastPathComponent == "wda-\(udid).pid")
        file.write(4242)
        #expect(file.read() == 4242)
        file.remove(ifHolding: 1234)
        #expect(file.read() == 4242)
        file.remove(ifHolding: 4242)
        #expect(file.read() == nil)
    }

    /// A stand-in for a test run that a crashed app left behind: a shell named "xcodebuild".
    @Test func stopsALeftoverTestRun() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fake = root.appendingPathComponent("xcodebuild")
        try FileManager.default.createSymbolicLink(at: fake, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        // "; true" keeps the shell from replacing itself with sleep.
        let leftover = try ChildProcess(fake.path, ["-c", "echo ready; sleep 60; true", "test-without-building", "id=\(udid)"])
        // /bin/sh execs bash. Once the shell prints, the exec is over and the command line stays.
        var output = leftover.lines.makeAsyncIterator()
        #expect(await output.next() == "ready")
        let file = TestRunPidFile(root: root, udid: udid)
        file.write(leftover.pid)
        #expect(await file.stopStaleRun(grace: .seconds(2)))
        #expect(await leftover.exitStatus() == 128 + SIGTERM)
        #expect(file.read() == nil)
    }

    @Test func leavesAnUnrelatedProcessAlone() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let unrelated = try ChildProcess("/bin/sleep", ["60"])
        let file = TestRunPidFile(root: root, udid: udid)
        file.write(unrelated.pid)
        #expect(await !file.stopStaleRun())
        #expect(kill(unrelated.pid, 0) == 0)
        #expect(file.read() == nil)
        await unrelated.terminate(grace: .milliseconds(300))
    }
}
