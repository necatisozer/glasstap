import Foundation

/// `~/Library/Application Support/glasstap`: the viewer link, the WDA source, its builds and the pid files.
public enum GlasstapFolder {
    public static let url = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("glasstap")

    /// Creates the folder with owner-only access (700), and tightens a looser mode, because the
    /// folder holds the viewer token.
    @discardableResult
    public static func ensurePrivate(_ folder: URL = url) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        return folder
    }
}
