import Foundation

/// The link that opens the viewer, and a private file that holds it. A viewer on
/// another Mac reads the file over SSH, because "Copy Viewer Link" works only at this Mac's screen.
public struct ViewerLink: Sendable {
    /// The token goes in the fragment, which the browser never sends to a server. `device` names
    /// one iPhone. Without it, the page uses the only iPhone, or asks which one. `host` is the
    /// address that the listeners are bound to.
    public static func url(controlPort: UInt16, token: AccessToken, device: String? = nil,
                           host: String = ListenAddress.loopback) -> URL {
        var link = "http://\(IPLiteral.urlHost(host)):\(controlPort)/#token=\(token.value)"
        if let device, let encoded = device.addingPercentEncoding(withAllowedCharacters: idCharacters) {
            link += "&device=\(encoded)"
        }
        return URL(string: link)!
    }

    /// A UDID needs no escape. A capture id can hold any character.
    private static let idCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    public static let defaultFile = GlasstapFolder.url.appendingPathComponent("viewer-link")

    public let file: URL

    public init(file: URL = ViewerLink.defaultFile) {
        self.file = file
    }

    /// Writes the link with owner-only access (folder 700, file 600), because it holds the token.
    public func write(_ url: URL) throws {
        let fm = FileManager.default
        try GlasstapFolder.ensurePrivate(file.deletingLastPathComponent())
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
