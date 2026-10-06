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
    /// The host and the port of a Host header or of the authority of an origin: "[v6]:port",
    /// "[v6]", "v4:port", "name:port" or "name". nil for anything else, such as an IPv6 address without brackets.
    static func splitHost(_ authority: String) -> (host: String, port: String?)? {
        func validPort(_ port: Substring) -> Bool { !port.isEmpty && port.allSatisfy(\.isASCII) && port.allSatisfy(\.isNumber) }
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            let host = String(authority[authority.index(after: authority.startIndex)..<close])
            let rest = authority[authority.index(after: close)...]
            if rest.isEmpty { return (host, nil) }
            guard rest.first == ":", validPort(rest.dropFirst()) else { return nil }
            return (host, String(rest.dropFirst()))
        }
        let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1: return (authority, nil)
        case 2 where validPort(parts[1]): return (String(parts[0]), String(parts[1]))
        default: return nil
        }
    }

    /// The Host check of both listeners. 127.0.0.1 and localhost always pass, because a tunnel such
    /// as `ssh -L` keeps them. The chosen listen address passes too, in any text form of the same
    /// address. Every other name fails, so that a foreign site name that points at this Mac
    /// (DNS rebinding) cannot reach the listeners.
    public static func isAllowedHost(_ hostHeader: String?, listen: String) -> Bool {
        guard let hostHeader, let host = splitHost(hostHeader)?.host else { return false }
        // An IPv6 host must be in brackets, and nothing else may be.
        let bracketed = hostHeader.hasPrefix("[")
        if !bracketed && (host == ListenAddress.loopback || host == "localhost") { return true }
        guard listen != ListenAddress.loopback, bracketed == host.contains(":"),
              let canonical = IPLiteral.canonical(host)
        else { return false }
        return canonical == IPLiteral.canonical(listen)
    }

    /// The check of the control listener: page, actions, info and screenshot. `listen` is the
    /// address that the listener is bound to.
    public static func controlAllows(_ request: HTTPRequest, token: AccessToken, listen: String = ListenAddress.loopback) -> Bool {
        let host = request.header("host") ?? ""
        guard isAllowedHost(host, listen: listen) else { return false }
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

    /// The origins of the viewer page, which alone may read the stream. They follow the listen address.
    public static func viewerOrigins(controlPort: UInt16, listen: String = ListenAddress.loopback) -> Set<String> {
        var origins: Set<String> = ["http://127.0.0.1:\(controlPort)", "http://localhost:\(controlPort)"]
        if listen != ListenAddress.loopback, let address = IPLiteral.canonical(listen) {
            origins.insert("http://\(IPLiteral.urlHost(address)):\(controlPort)")
        }
        return origins
    }

    /// An origin with its IP host in canonical form, so that two spellings of one address compare equal.
    static func canonicalOrigin(_ origin: String) -> String {
        guard origin.hasPrefix("http://"), let (host, port) = splitHost(String(origin.dropFirst("http://".count))),
              let address = IPLiteral.canonical(host)
        else { return origin }
        return "http://\(IPLiteral.urlHost(address))" + (port.map { ":\($0)" } ?? "")
    }

    /// The check of the video listener. `listen` is the address that the listener is bound to.
    public static func video(_ request: HTTPRequest, token: AccessToken, viewerOrigins: Set<String>,
                             listen: String = ListenAddress.loopback) -> VideoDecision {
        guard isAllowedHost(request.header("host"), listen: listen) else { return .reject(status: 403) }
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
            guard viewerOrigins.contains(origin) || viewerOrigins.contains(canonicalOrigin(origin)) else { return .reject(status: 403) }
            return .accept(corsOrigin: origin)
        }
        if request.header("sec-fetch-site") == "cross-site" { return .reject(status: 403) }
        return .accept(corsOrigin: nil)
    }
}
