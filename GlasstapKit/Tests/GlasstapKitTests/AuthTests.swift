import Foundation
import Testing
@testable import GlasstapKit

@Suite struct AuthTests {
    let token = AccessToken(value: "0123456789abcdef0123456789abcdef")
    let origins = Auth.viewerOrigins(controlPort: 9300)

    func req(_ method: String, _ target: String, _ headers: [(String, String)]) -> HTTPRequest {
        HTTPRequest(method: method, target: target, headers: headers.map { (name: $0.0, value: $0.1) })
    }

    @Test func generatedTokenIs32HexCharacters() {
        let a = AccessToken.generate(), b = AccessToken.generate()
        #expect(a.value.count == 32)
        #expect(a.value.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(a != b)
    }

    @Test func tokenComparison() {
        #expect(token.matches(token.value))
        #expect(!token.matches(nil))
        #expect(!token.matches(""))
        #expect(!token.matches(String(token.value.dropLast())))
        #expect(!token.matches(String(token.value.dropLast()) + "0"))
        #expect(!AccessToken(value: "").matches(""))
    }

    @Test func hostCheck() {
        func allowed(_ host: String?) -> Bool { Auth.isAllowedHost(host, listen: ListenAddress.loopback) }
        #expect(allowed("127.0.0.1"))
        #expect(allowed("127.0.0.1:9300"))
        #expect(allowed("localhost:9301"))
        #expect(!allowed(nil))
        #expect(!allowed(""))
        #expect(!allowed("evil.example:9300"))
        #expect(!allowed("127.0.0.1.evil.example"))
        #expect(!allowed("[::1]:9300"))
        #expect(!allowed("[127.0.0.1]:9300"))
        // A port must be digits.
        #expect(!allowed("127.0.0.1:"))
        #expect(!allowed("localhost:x"))
    }

    @Test func controlPageLoadsWithoutToken() {
        #expect(Auth.controlAllows(req("GET", "/", [("Host", "127.0.0.1:9300")]), token: token))
        // The page still needs a loopback Host.
        #expect(!Auth.controlAllows(req("GET", "/", [("Host", "evil.example:9300")]), token: token))
        #expect(!Auth.controlAllows(req("GET", "/", []), token: token))
        // Only the page itself is free.
        #expect(!Auth.controlAllows(req("GET", "/info", [("Host", "127.0.0.1:9300")]), token: token))
        #expect(!Auth.controlAllows(req("POST", "/", [("Host", "127.0.0.1:9300")]), token: token))
    }

    @Test func controlToken() {
        let host = ("Host", "localhost:9300")
        #expect(Auth.controlAllows(req("POST", "/tap", [host, ("X-Glasstap", token.value)]), token: token))
        #expect(Auth.controlAllows(req("GET", "/screenshot?token=\(token.value)", [host]), token: token))
        #expect(Auth.controlAllows(req("GET", "/info", [host, ("X-Glasstap", "")]), token: token) == false)
        #expect(Auth.controlAllows(req("GET", "/screenshot?token=\(token.value)", [host, ("X-Glasstap", "")]), token: token))
        #expect(!Auth.controlAllows(req("POST", "/tap", [host]), token: token))
        #expect(!Auth.controlAllows(req("POST", "/tap", [host, ("X-Glasstap", "wrong")]), token: token))
        #expect(!Auth.controlAllows(req("POST", "/tap", [("Host", "evil.example"), ("X-Glasstap", token.value)]), token: token))
    }

    @Test func controlOrigin() {
        let host = ("Host", "127.0.0.1:9300"), auth = ("X-Glasstap", token.value)
        #expect(Auth.controlAllows(req("POST", "/tap", [host, auth, ("Origin", "http://127.0.0.1:9300")]), token: token))
        #expect(!Auth.controlAllows(req("POST", "/tap", [host, auth, ("Origin", "http://evil.example")]), token: token))
        #expect(!Auth.controlAllows(req("POST", "/tap", [host, auth, ("Origin", "http://localhost:9300")]), token: token))
        #expect(!Auth.controlAllows(req("POST", "/tap", [host, auth, ("Origin", "null")]), token: token))
        // The Origin rule is for POST. A GET still needs the token.
        #expect(Auth.controlAllows(req("GET", "/info", [host, auth, ("Origin", "http://evil.example")]), token: token))
    }

    @Test func videoAcceptsTheViewer() {
        let r = req("GET", "/video?token=\(token.value)", [("Host", "127.0.0.1:9301"), ("Origin", "http://127.0.0.1:9300"),
                                                          ("Sec-Fetch-Site", "same-site")])
        #expect(Auth.video(r, token: token, viewerOrigins: origins)
            == .accept(corsOrigin: "http://127.0.0.1:9300"))
        let plain = req("GET", "/video?token=\(token.value)", [("Host", "localhost:9301")])
        #expect(Auth.video(plain, token: token, viewerOrigins: origins) == .accept(corsOrigin: nil))
    }

    @Test func videoRejections() {
        let good = "/video?token=\(token.value)"
        func check(_ target: String, _ headers: [(String, String)], method: String = "GET") -> Auth.VideoDecision {
            Auth.video(req(method, target, headers), token: token, viewerOrigins: origins)
        }
        #expect(check(good, [("Host", "evil.example:9301")]) == .reject(status: 403))
        #expect(check("/", [("Host", "127.0.0.1:9301")]) == .reject(status: 404))
        #expect(check("/videos?token=\(token.value)", [("Host", "127.0.0.1:9301")]) == .reject(status: 404))
        #expect(check(good, [("Host", "127.0.0.1:9301")], method: "POST") == .reject(status: 404))
        #expect(check("/video", [("Host", "127.0.0.1:9301")]) == .reject(status: 403))
        #expect(check("/video?token=nope", [("Host", "127.0.0.1:9301")]) == .reject(status: 403))
        // The token in a header does not count for video.
        #expect(check("/video", [("Host", "127.0.0.1:9301"), ("X-Glasstap", token.value)]) == .reject(status: 403))
        #expect(check(good, [("Host", "127.0.0.1:9301"), ("Origin", "http://evil.example")]) == .reject(status: 403))
        #expect(check(good, [("Host", "127.0.0.1:9301"), ("Origin", "http://127.0.0.1:9301")]) == .reject(status: 403))
        #expect(check(good, [("Host", "127.0.0.1:9301"), ("Sec-Fetch-Site", "cross-site")]) == .reject(status: 403))
    }
}
