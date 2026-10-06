import Foundation
import Testing
@testable import GlasstapKit

@Suite struct HTTPRequestTests {
    func parse(_ text: String) -> HTTPParseResult { HTTPParser.parse(Data(text.utf8)) }

    func request(_ text: String) throws -> HTTPRequest {
        guard case let .complete(r) = parse(text) else {
            Issue.record("not complete: \(text)")
            throw CancellationError()
        }
        return r
    }

    @Test func requestLinePathAndQuery() throws {
        let r = try request("GET /video?token=ab%20c&x=1&token=second HTTP/1.1\r\nHost: 127.0.0.1:9301\r\n\r\n")
        #expect(r.method == "GET")
        #expect(r.target == "/video?token=ab%20c&x=1&token=second")
        #expect(r.path == "/video")
        #expect(r.queryValue("token") == "ab c")
        #expect(r.queryValue("x") == "1")
        #expect(r.queryValue("missing") == nil)
    }

    @Test func headersMatchWithoutCase() throws {
        let r = try request("GET / HTTP/1.1\r\nHOST: localhost\r\nx-GlassTap:  abc \r\nOrigin: http://a\r\nOrigin: http://b\r\n\r\n")
        #expect(r.header("host") == "localhost")
        #expect(r.header("Host") == "localhost")
        #expect(r.header("X-Glasstap") == "abc")
        #expect(r.header("origin") == "http://a")
        #expect(r.header("sec-fetch-site") == nil)
    }

    @Test func waitsForTheWholeHeaderAndBody() throws {
        #expect(parse("GET / HTTP/1.1\r\nHost: localhost\r\n") == .incomplete)
        #expect(parse("POST /tap HTTP/1.1\r\nContent-Length: 10\r\n\r\n{\"x\":") == .incomplete)
        let r = try request("POST /tap HTTP/1.1\r\nContent-Length: 14\r\n\r\n{\"x\":1,\"y\":2}xx")
        #expect(String(decoding: r.body, as: UTF8.self) == "{\"x\":1,\"y\":2}x")
    }

    @Test func rejectsMalformedRequests() {
        #expect(parse("GET /\r\n\r\n") == .invalid)
        #expect(parse("GET / FTP/1.0\r\n\r\n") == .invalid)
        #expect(parse("GET / HTTP/1.1\r\nno colon here\r\n\r\n") == .invalid)
        #expect(parse("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n") == .invalid)
        #expect(parse("POST / HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n") == .invalid)
        #expect(parse("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") == .invalid)
        #expect(HTTPParser.parse(Data(repeating: 0x41, count: HTTPParser.maxHeaderBytes + 1)) == .invalid)
    }

    @Test func responseClosesTheConnection() {
        let text = String(decoding: HTTPResponse.text(403, "forbidden").serialized, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
        #expect(text.contains("Content-Length: 9\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(text.hasSuffix("\r\n\r\nforbidden"))
    }
}
