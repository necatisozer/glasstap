import Foundation

/// One parsed HTTP/1.x request. Header names are stored in lower case.
public struct HTTPRequest: Sendable, Equatable {
    public let method: String
    /// The request target as sent, with the query.
    public let target: String
    /// The target without the query. It stays percent-encoded.
    public let path: String
    public let query: [URLQueryItem]
    public let headers: [(name: String, value: String)]
    public let body: Data

    public init(method: String, target: String, headers: [(name: String, value: String)], body: Data = Data()) {
        self.method = method
        self.target = target
        let components = URLComponents(string: target)
        path = components?.percentEncodedPath ?? target
        query = components?.queryItems ?? []
        self.headers = headers.map { ($0.name.lowercased(), $0.value) }
        self.body = body
    }

    /// The first value of a header, matched without regard to case.
    public func header(_ name: String) -> String? {
        let name = name.lowercased()
        return headers.first { $0.name == name }?.value
    }

    /// The first value of a query parameter, percent-decoded.
    public func queryValue(_ name: String) -> String? {
        query.first { $0.name == name }?.value
    }

    public static func == (a: HTTPRequest, b: HTTPRequest) -> Bool {
        a.method == b.method && a.target == b.target && a.body == b.body
            && a.headers.map(\.name) == b.headers.map(\.name) && a.headers.map(\.value) == b.headers.map(\.value)
    }
}

public enum HTTPParseResult: Sendable, Equatable {
    /// More bytes are needed.
    case incomplete
    /// The bytes are not a request that this server accepts.
    case invalid
    case complete(HTTPRequest)
}

public enum HTTPParser {
    public static let maxHeaderBytes = 16 * 1024
    public static let maxBodyBytes = 64 * 1024

    private static let headerEnd = Data("\r\n\r\n".utf8)

    /// Parses the bytes received so far on a connection.
    public static func parse(_ data: Data) -> HTTPParseResult {
        guard let end = data.range(of: headerEnd) else {
            return data.count > maxHeaderBytes ? .invalid : .incomplete
        }
        guard end.lowerBound - data.startIndex <= maxHeaderBytes,
              let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8)
        else { return .invalid }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid }
        var headers: [(name: String, value: String)] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .invalid }
            headers.append((name, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        let method = String(requestLine[0]), target = String(requestLine[1])
        var request = HTTPRequest(method: method, target: target, headers: headers)
        // Chunked bodies are not supported. The viewer page always sends a Content-Length.
        if request.header("transfer-encoding") != nil { return .invalid }
        let length: Int
        if let value = request.header("content-length") {
            guard let n = Int(value), n >= 0, n <= maxBodyBytes else { return .invalid }
            length = n
        } else {
            length = 0
        }
        let bodyStart = end.upperBound
        guard data.endIndex - bodyStart >= length else { return .incomplete }
        if length > 0 {
            request = HTTPRequest(method: method, target: target, headers: headers,
                                  body: Data(data[bodyStart..<(bodyStart + length)]))
        }
        return .complete(request)
    }
}

/// A response. It closes the connection after it is sent, unless it is sent with `keepAlive`.
public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func text(_ status: Int, _ text: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "text/plain")], body: Data(text.utf8))
    }

    public static func json(_ body: Data) -> HTTPResponse {
        HTTPResponse(status: 200, headers: [("Content-Type", "application/json")], body: body)
    }

    public var serialized: Data {
        serialized(keepAlive: false)
    }

    public func serialized(keepAlive: Bool) -> Data {
        header(contentLength: body.count, keepAlive: keepAlive) + body
    }

    /// The status line and headers. A stream has no length: it ends when the connection closes.
    public func header(contentLength: Int?, keepAlive: Bool = false) -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        if let contentLength { head += "Content-Length: \(contentLength)\r\n" }
        head += keepAlive ? "Connection: keep-alive\r\n\r\n" : "Connection: close\r\n\r\n"
        return Data(head.utf8)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 502: "Bad Gateway"
        default: "Status"
        }
    }
}
