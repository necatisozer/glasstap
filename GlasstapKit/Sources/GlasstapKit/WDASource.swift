import CryptoKit
import Foundation

/// The WebDriverAgent source archive of one pinned release. The app never ships a signed WDA:
/// each user builds it with their own team. WDA uses the BSD-3-Clause licence.
public struct WDASource: Sendable {
    public enum InstallError: Error, CustomStringConvertible {
        case download(String)
        case hashMismatch(expected: String, actual: String)
        case extract(String)

        public var description: String {
            switch self {
            case let .download(reason): "The WebDriverAgent download failed: \(reason)"
            case let .hashMismatch(expected, actual):
                "The WebDriverAgent archive has the wrong SHA-256 (\(actual), expected \(expected)). glasstap did not use it."
            case let .extract(reason): "The WebDriverAgent archive could not be unpacked: \(reason)"
            }
        }
    }

    public static let pinned = WDASource(
        version: "16.12.10",
        url: URL(string: "https://github.com/appium/WebDriverAgent/archive/refs/tags/v16.12.10.tar.gz")!,
        sha256: "e6aa0e838c6a2d21096adadacf7ebcfa1389ef534dad9f3827a9871596dbbb9f")

    public let version: String
    public let url: URL
    public let sha256: String

    public init(version: String, url: URL, sha256: String) {
        self.version = version
        self.url = url
        self.sha256 = sha256
    }

    /// `<root>/WebDriverAgent/<version>`
    public func folder(in root: URL) -> URL {
        root.appending(path: "WebDriverAgent/\(version)", directoryHint: .isDirectory)
    }

    /// The source folder, if a complete one is in place. It only ever appears by an atomic move.
    public func installed(in root: URL) -> URL? {
        let folder = folder(in: root)
        let project = folder.appendingPathComponent("WebDriverAgent.xcodeproj")
        return FileManager.default.fileExists(atPath: project.path) ? folder : nil
    }

    /// Downloads, verifies and unpacks the archive, then moves the source into place.
    public func install(in root: URL, session: URLSession = URLSession(configuration: .ephemeral)) async throws -> URL {
        if let folder = installed(in: root) { return folder }
        let fm = FileManager.default
        let parent = root.appendingPathComponent("WebDriverAgent")
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        // A staging folder next to the target, so that the final move is a rename on one volume.
        let staging = parent.appendingPathComponent(".staging-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }

        let archive = staging.appendingPathComponent("source.tar.gz")
        do {
            let (downloaded, response) = try await session.download(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                try? fm.removeItem(at: downloaded)
                throw InstallError.download("HTTP \(http.statusCode)")
            }
            try fm.moveItem(at: downloaded, to: archive)
        } catch let error as InstallError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw InstallError.download(error.localizedDescription)
        }

        let actual = try Self.sha256(of: archive)
        guard actual == sha256.lowercased() else { throw InstallError.hashMismatch(expected: sha256, actual: actual) }

        let unpacked = staging.appendingPathComponent("unpacked")
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: false)
        let tar = try await ChildProcess.run("/usr/bin/tar", ["-xzf", archive.path, "-C", unpacked.path], keepLines: 5,
                                           timeout: .seconds(120))
        guard tar.status == 0 else { throw InstallError.extract(tar.lines.last ?? "tar exit status \(tar.status)") }
        // GitHub puts the source in one folder, WebDriverAgent-<version>.
        let inner = unpacked.appendingPathComponent("WebDriverAgent-\(version)")
        guard fm.fileExists(atPath: inner.appendingPathComponent("WebDriverAgent.xcodeproj").path) else {
            throw InstallError.extract("no WebDriverAgent-\(version)/WebDriverAgent.xcodeproj in the archive")
        }
        let target = folder(in: root)
        do {
            try fm.moveItem(at: inner, to: target)
        } catch {
            // Another install may have finished first.
            if let folder = installed(in: root) { return folder }
            throw error
        }
        return target
    }

    static func sha256(of file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }
}
