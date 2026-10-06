import Foundation
import Testing
@testable import GlasstapKit

@Suite struct ViewerLinkTests {
    let token = AccessToken(value: "0123456789abcdef0123456789abcdef")

    func mode(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    @Test func url() {
        #expect(ViewerLink.url(controlPort: 9300, token: token).absoluteString
            == "http://127.0.0.1:9300/#token=0123456789abcdef0123456789abcdef")
    }

    @Test func fileIsPrivate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glasstap-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let link = ViewerLink(file: root.appendingPathComponent("glasstap/viewer-link"))
        try link.write(ViewerLink.url(controlPort: 9300, token: token))
        #expect(try mode(link.file) == 0o600)
        #expect(try mode(link.file.deletingLastPathComponent()) == 0o700)
        #expect(try String(contentsOf: link.file, encoding: .utf8)
            == "http://127.0.0.1:9300/#token=0123456789abcdef0123456789abcdef\n")

        // A port change rewrites it, and a loose folder mode is tightened again.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: link.file.deletingLastPathComponent().path)
        try link.write(ViewerLink.url(controlPort: 9400, token: token))
        #expect(try String(contentsOf: link.file, encoding: .utf8).hasPrefix("http://127.0.0.1:9400/"))
        #expect(try mode(link.file) == 0o600)
        #expect(try mode(link.file.deletingLastPathComponent()) == 0o700)

        link.remove()
        #expect(!FileManager.default.fileExists(atPath: link.file.path))
    }
}
