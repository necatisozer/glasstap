import Darwin
import Foundation
import Testing
@testable import GlasstapKit

@Suite struct ChildProcessTests {
    @Test func collectsStdoutAndStderrAndTheStatus() async throws {
        let output = try await ChildProcess.run("/bin/sh", ["-c", "echo one; echo two >&2; printf three; exit 3"])
        #expect(output.status == 3)
        #expect(output.lines == ["one", "two", "three"])
    }

    @Test func keepsOnlyTheLastLines() async throws {
        let output = try await ChildProcess.run("/bin/sh", ["-c", "for i in 1 2 3 4 5; do echo $i; done"], keepLines: 2)
        #expect(output.lines == ["4", "5"])
    }

    @Test func passesTheEnvironment() async throws {
        let output = try await ChildProcess.run("/bin/sh", ["-c", "echo $NSUnbufferedIO"], environment: ["NSUnbufferedIO": "YES"])
        #expect(output.lines == ["YES"])
    }

    @Test func aMissingProgramThrows() {
        #expect(throws: ChildProcess.SpawnError.self) { try ChildProcess("/nonexistent/tool", []) }
    }

    /// The child is a group leader, so a stop also ends what the child started.
    @Test func terminateStopsTheWholeGroup() async throws {
        let child = try ChildProcess("/bin/sh", ["-c", "sleep 60 & echo $!; wait"])
        var iterator = child.lines.makeAsyncIterator()
        let grandchild = try #require(await iterator.next().flatMap { pid_t($0) })
        #expect(getpgid(child.pid) == child.pid)
        #expect(getpgid(grandchild) == child.pid)
        await child.terminate(grace: .seconds(5))
        #expect(await child.exitStatus() == 128 + SIGTERM)
        // The orphan is reaped by launchd shortly after it ends.
        #expect(await eventually { kill(grandchild, 0) == -1 && errno == ESRCH })
    }

    @Test func aChildThatIgnoresSIGTERMGetsSIGKILL() async throws {
        let child = try ChildProcess("/bin/sh", ["-c", "trap '' TERM; echo ready; while :; do sleep 1; done"])
        var iterator = child.lines.makeAsyncIterator()
        #expect(await iterator.next() == "ready")
        let start = ContinuousClock.now
        await child.terminate(grace: .milliseconds(300))
        #expect(await child.exitStatus() == 128 + SIGKILL)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func cancellingRunStopsTheChild() async throws {
        let task = Task { try await ChildProcess.run("/bin/sh", ["-c", "echo started; sleep 60"]) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@Suite struct ChildProcessGroupTests {
    /// The leader ends at SIGTERM, but a member of its group ignores it. The member must get SIGKILL.
    @Test func aMemberThatOutlivesTheLeaderGetsSIGKILL() async throws {
        let child = try ChildProcess("/bin/sh", ["-c", "sh -c 'trap \"\" TERM; echo $$; while :; do sleep 1; done' & wait"])
        var iterator = child.lines.makeAsyncIterator()
        let member = try #require(await iterator.next().flatMap { pid_t($0) })
        #expect(getpgid(member) == child.pid)
        let start = ContinuousClock.now
        await child.terminate(grace: .milliseconds(300))
        // terminate returns only when the whole group is gone.
        #expect(kill(-child.pid, 0) == -1 && errno == ESRCH)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    /// A process outside the group can hold the pipe open. The reader must still end and close it.
    @Test func noPipeOutlivesTheRun() async throws {
        let child = try ChildProcess("/usr/bin/perl", ["-e", "if (my $pid = fork) { print \"$pid\\n\"; exit 0 } setpgrp(0, 0); sleep 30"])
        var outsider: pid_t?
        for await line in child.lines { outsider = outsider ?? pid_t(line) }
        // The output ends 2 s after the exit, though the outsider keeps the pipe open.
        await child.terminate(grace: .milliseconds(300))
        #expect(await eventually { child.isPipeClosed })
        let outsiderPid = try #require(outsider)
        // The outsider is in a group of its own, so the stop did not reach it.
        #expect(kill(outsiderPid, 0) == 0)
        kill(outsiderPid, SIGKILL)
    }

    @Test func runStopsACommandThatTakesTooLong() async throws {
        let start = ContinuousClock.now
        await #expect(throws: ChildProcess.Timeout.self) {
            try await ChildProcess.run("/bin/sh", ["-c", "echo started; sleep 60"], timeout: .milliseconds(300))
        }
        #expect(ContinuousClock.now - start < .seconds(10))
    }
}
