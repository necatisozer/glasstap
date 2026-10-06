import Foundation

/// The access token of one app launch. It is kept in memory only.
public struct AccessToken: Sendable, Equatable {
    public let value: String

    public init(value: String) { self.value = value }

    /// 16 random bytes as 32 hex characters.
    public static func generate() -> AccessToken {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        return AccessToken(value: bytes.map { String(format: "%02x", $0) }.joined())
    }

    /// Compares in constant time for a given length, so that the reply time does not leak the token.
    public func matches(_ candidate: String?) -> Bool {
        guard let candidate, !value.isEmpty else { return false }
        let a = Array(value.utf8), b = Array(candidate.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

public enum Auth {
    /// Rejects DNS rebinding: a foreign site name that points at 127.0.0.1.
    public static func isLoopbackHost(_ hostHeader: String?) -> Bool {
        guard let hostHeader else { return false }
        let host = hostHeader.lastIndex(of: ":").map { String(hostHeader[..<$0]) } ?? hostHeader
        return host == "127.0.0.1" || host == "localhost"
    }

    /// The check of the control listener: page, actions, info and screenshot.
    public static func controlAllows(_ request: HTTPRequest, token: AccessToken) -> Bool {
        let host = request.header("host") ?? ""
        guard isLoopbackHost(host) else { return false }
        if request.method == "POST", let origin = request.header("origin"), origin != "http://\(host)" {
            return false
        }
        // The page sends the token in a custom header. A cross-site request with a
        // custom header needs a CORS preflight, and this server never grants one.
        // The page itself holds no secret, so it loads without the token. It reads
        // the token from the URL fragment, which the browser never sends to a server.
        if request.method == "GET" && request.path == "/" { return true }
        let header = request.header("x-glasstap").flatMap { $0.isEmpty ? nil : $0 }
        return token.matches(header ?? request.queryValue("token"))
    }

    public enum VideoDecision: Sendable, Equatable {
        case reject(status: Int)
        /// `corsOrigin` is the viewer origin to allow in CORS, if the request named one.
        case accept(corsOrigin: String?)
    }

    /// The origins of the viewer page, which alone may read the stream.
    public static func viewerOrigins(controlPort: UInt16) -> Set<String> {
        ["http://127.0.0.1:\(controlPort)", "http://localhost:\(controlPort)"]
    }

    /// The check of the video listener.
    public static func video(_ request: HTTPRequest, token: AccessToken, viewerOrigins: Set<String>) -> VideoDecision {
        guard isLoopbackHost(request.header("host")) else { return .reject(status: 403) }
        // Serve only /video and /devices/<id>/video, so that stray requests from other pages
        // cannot take the stream from the viewer.
        guard request.method == "GET", case let .route(_, rest)? = DevicePath.parse(request.path), rest == "/video" else {
            return .reject(status: 404)
        }
        // Require the token, so that other local users cannot read the screen.
        guard token.matches(request.queryValue("token")) else { return .reject(status: 403) }
        // Only the viewer page may read the stream. "*" would let any website read the screen.
        // A request from another website must not take the stream either, so refuse it.
        // Browsers send Sec-Fetch-Site even where they send no Origin (for <img> or <video>).
        if let origin = request.header("origin") {
            guard viewerOrigins.contains(origin) else { return .reject(status: 403) }
            return .accept(corsOrigin: origin)
        }
        if request.header("sec-fetch-site") == "cross-site" { return .reject(status: 403) }
        return .accept(corsOrigin: nil)
    }
}
