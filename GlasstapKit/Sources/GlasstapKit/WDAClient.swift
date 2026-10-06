import Foundation

/// The only WDA client. The browser never reaches WDA: WDA allows any origin and
/// has no authentication, so the app offers only a fixed set of actions.
public actor WDAClient {
    /// WDA answered with an HTTP error.
    public struct WDAError: Error, CustomStringConvertible {
        public let status: Int
        public let body: String

        /// WDA no longer knows the session, for example after a restart. Only then is a
        /// retry safe: WDA did not perform the action, so a tap cannot happen twice.
        var isInvalidSession: Bool {
            guard status == 404,
                  let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
                  let value = json["value"] as? [String: Any]
            else { return false }
            return value["error"] as? String == "invalid session id"
        }

        public var description: String { "WDA \(status): \(body.prefix(200))" }
    }

    public struct ReplyError: Error, CustomStringConvertible {
        public let description: String
    }

    /// The one session for requests to WDA. WDA is on the iPhone's tunnel address, which no proxy can reach.
    static let urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// The WDA base URL now, or nil while no WDA runs. It changes when WDA starts again.
    private let endpoint: @Sendable () -> URL?
    /// A WDA session belongs to the WDA at one address.
    private var session: (url: URL, id: String, size: ScreenSize)?

    public init(endpoint: @escaping @Sendable () -> URL?) {
        self.endpoint = endpoint
    }

    public init(baseURL: URL?) {
        self.init(endpoint: { baseURL })
    }

    /// True if `GET /status` answers 200 with a JSON object within 3 s.
    public static func isReachable(_ baseURL: URL) async -> Bool {
        let request = URLRequest(url: baseURL.appending(path: WDARequest.status.path), timeoutInterval: 3)
        guard let (data, response) = try? await urlSession.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }

    private func call(_ wda: WDARequest, timeout: TimeInterval = 30) async throws -> [String: Any] {
        guard let baseURL = endpoint() else { throw ReplyError(description: "WDA is not running") }
        var request = URLRequest(url: baseURL.appending(path: wda.path), timeoutInterval: timeout)
        request.httpMethod = wda.method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = wda.body
        let (data, response) = try await Self.urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 {
            throw WDAError(status: status, body: String(decoding: data, as: UTF8.self))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReplyError(description: "WDA sent no JSON object")
        }
        return json
    }

    /// Reuses the cached session, or the one that WDA reports, or creates one. Also fetches the window size.
    private func currentSession() async throws -> (id: String, size: ScreenSize) {
        guard let url = endpoint() else { throw ReplyError(description: "WDA is not running") }
        if let session, session.url == url { return (session.id, session.size) }
        var id = try await call(.status)["sessionId"] as? String
        if id == nil { id = try await call(.createSession)["sessionId"] as? String }
        guard let id else { throw ReplyError(description: "WDA gave no session id") }
        let value = try await call(.windowSize(id))["value"] as? [String: Any]
        // Bounded, so that the gestures computed from it cannot trap in a conversion to Int.
        guard let w = (value?["width"] as? NSNumber)?.doubleValue, let h = (value?["height"] as? NSNumber)?.doubleValue,
              (1..<100_000).contains(w), (1..<100_000).contains(h) else {
            throw ReplyError(description: "WDA gave no window size")
        }
        let size = ScreenSize(width: w, height: h)
        session = (url, id, size)
        return (id, size)
    }

    /// Runs `body` in the cached session. If WDA no longer knows that session, gets a fresh one and tries once more.
    private func withSession<T>(_ body: (String, ScreenSize) async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            let s = try await currentSession()
            do {
                return try await body(s.id, s.size)
            } catch let error as WDAError where error.isInvalidSession && attempt == 1 {
                session = nil
                attempt += 1
            }
        }
    }

    public func perform(_ action: ControlAction) async throws {
        try await withSession { sid, size in
            _ = try await call(action.wdaRequest(sessionID: sid, size: size))
        }
    }

    /// The window size in points.
    public func windowSize() async throws -> ScreenSize {
        try await currentSession().size
    }

    /// True while the iPhone shows its lock screen or has its display off. WDA answers `{"value": true}`.
    public func isLocked() async throws -> Bool {
        // Shorter than the 5 s of the viewer page, so that a slow answer does not outlive the question.
        guard let locked = try await call(.locked, timeout: 4)["value"] as? Bool else {
            throw ReplyError(description: "WDA gave no lock state")
        }
        return locked
    }

    /// A full-resolution PNG of the screen.
    public func screenshot() async throws -> Data {
        guard let base64 = try await call(.screenshot)["value"] as? String,
              let png = Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
        else { throw ReplyError(description: "WDA gave no screenshot") }
        return png
    }

    /// The capture sends no frames while the display is off. On the lock or home
    /// screen, Home wakes the display and does nothing else. In an app it would
    /// leave the app, so only SpringBoard gets it. Returns true if it pressed Home.
    public func wakeIfSpringBoardIsInFront() async -> Bool {
        do {
            // A freshly started WDA has no session yet. This creates one.
            let sid = try await currentSession().id
            let info = try await call(.activeAppInfo(sid), timeout: 10)
            guard (info["value"] as? [String: Any])?["bundleId"] as? String == "com.apple.springboard" else { return false }
            _ = try await call(.pressHome(sid), timeout: 20)
            return true
        } catch {
            return false
        }
    }
}
