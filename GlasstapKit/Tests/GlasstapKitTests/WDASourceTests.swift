import Foundation
import Testing
@testable import GlasstapKit

@Suite struct WDASourceTests {
    let fm = FileManager.default

    /// A small archive with the layout of a GitHub release: WebDriverAgent-<version>/WebDriverAgent.xcodeproj.
    func makeArchive(in folder: URL, version: String) async throws -> URL {
        let tree = folder.appendingPathComponent("tree")
        let project = tree.appendingPathComponent("WebDriverAgent-\(version)/WebDriverAgent.xcodeproj")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("// project".utf8).write(to: project.appendingPathComponent("project.pbxproj"))
        let archive = folder.appendingPathComponent("wda.tar.gz")
        let tar = try await ChildProcess.run("/usr/bin/tar", ["-czf", archive.path, "-C", tree.path, "WebDriverAgent-\(version)"])
        #expect(tar.status == 0)
        return archive
    }

    func temporaryFolder() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("glasstap-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func installsAVerifiedArchive() async throws {
        let folder = try temporaryFolder()
        defer { try? fm.removeItem(at: folder) }
        let archive = try await makeArchive(in: folder, version: "1.2.3")
        let source = WDASource(version: "1.2.3", url: archive, sha256: try WDASource.sha256(of: archive))
        let root = folder.appendingPathComponent("support")
        #expect(source.installed(in: root) == nil)

        let installed = try await source.install(in: root)
        #expect(installed.path == root.appendingPathComponent("WebDriverAgent/1.2.3").path)
        #expect(source.installed(in: root) == installed)
        #expect(fm.fileExists(atPath: installed.appendingPathComponent("WebDriverAgent.xcodeproj/project.pbxproj").path))
        // No staging folder stays behind.
        #expect(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("WebDriverAgent").path) == ["1.2.3"])
    }

    @Test func refusesAnArchiveWithTheWrongHash() async throws {
        let folder = try temporaryFolder()
        defer { try? fm.removeItem(at: folder) }
        let archive = try await makeArchive(in: folder, version: "1.2.3")
        let source = WDASource(version: "1.2.3", url: archive, sha256: String(repeating: "0", count: 64))
        let root = folder.appendingPathComponent("support")
        await #expect {
            try await source.install(in: root)
        } throws: { error in
            guard case WDASource.InstallError.hashMismatch = error else { return false }
            return true
        }
        #expect(source.installed(in: root) == nil)
        #expect(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("WebDriverAgent").path).isEmpty)
    }

    @Test func thePinnedRelease() {
        #expect(WDASource.pinned.version == "16.12.10")
        #expect(WDASource.pinned.sha256 == "e6aa0e838c6a2d21096adadacf7ebcfa1389ef534dad9f3827a9871596dbbb9f")
    }
}
