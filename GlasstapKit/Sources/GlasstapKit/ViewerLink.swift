import Foundation

/// The link that opens the viewer, and a private file that holds it. A viewer on
/// another Mac reads the file over SSH, because "Copy Viewer Link" works only at this Mac's screen.
public struct ViewerLink: Sendable {
    /// The token goes in the fragment, which the browser never sends to a server.
    public static func url(controlPort: UInt16, token: AccessToken) -> URL {
        URL(string: "http://127.0.0.1:\(controlPort)/#token=\(token.value)")!
    }

    public static let defaultFile = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("glasstap/viewer-link")

    public let file: URL

    public init(file: URL = ViewerLink.defaultFile) {
        self.file = file
    }

    /// Writes the link with owner-only access (folder 700, file 600), because it holds the token.
    public func write(_ url: URL) throws {
        let fm = FileManager.default
        let folder = file.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        // A new file gets mode 600 at creation, so the token is never readable by others.
        try? fm.removeItem(at: file)
        guard fm.createFile(atPath: file.path, contents: Data((url.absoluteString + "\n").utf8),
                            attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path]) }
    }

    /// Deletes the file, at quit, because its token stops working then.
    public func remove() {
        try? FileManager.default.removeItem(at: file)
    }
}
