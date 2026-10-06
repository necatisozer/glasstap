import Darwin
import Foundation

/// An address of this Mac that the two listeners can bind to, instead of 127.0.0.1.
public struct ListenAddress: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// In 100.64.0.0/10 or fd7a:115c:a1e0::/48, the ranges that Tailscale gives out.
        case tailscale
        case other
    }

    /// "This Mac only", the default.
    public static let loopback = "127.0.0.1"

    /// In the canonical form of `IPLiteral.canonical`.
    public let address: String
    public let interface: String
    public let kind: Kind

    public var id: String { address }

    public init(address: String, interface: String, kind: Kind) {
        self.address = address
        self.interface = interface
        self.kind = kind
    }

    /// The kind of an address, or nil for one that the settings do not offer: a loopback address
    /// (127.0.0.1 is "This Mac only"), a link-local address (it needs a scope, and changes with
    /// the interface), and the unspecified address (it would listen on every interface).
    public static func classify(_ address: String) -> Kind? {
        if let v4 = IPLiteral.ipv4Bytes(address) {
            switch (v4[0], v4[1]) {
            case (0, _), (127, _), (169, 254): return nil
            case (100, 64...127): return .tailscale
            default: return .other
            }
        }
        if let v6 = IPLiteral.ipv6Bytes(address) {
            if v6.dropLast().allSatisfy({ $0 == 0 }) && (v6[15] == 0 || v6[15] == 1) { return nil }
            if v6[0] == 0xfe && v6[1] & 0xc0 == 0x80 { return nil }
            if Array(v6.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] { return .tailscale }
            return .other
        }
        return nil
    }

    /// The kind of an address on `interface`, or nil if the settings do not offer it. Besides the
    /// addresses that `classify` skips, a `utun` interface is offered only with a Tailscale address:
    /// the CoreDevice tunnel of each iPhone is a `utun` interface with an fd… address, which
    /// changes at each plug-in and which the Mac itself could not reach.
    public static func offerable(_ address: String, interface: String) -> Kind? {
        guard let kind = classify(address) else { return nil }
        if interface.hasPrefix("utun") && kind != .tailscale { return nil }
        return kind
    }

    /// True for an address that the listeners may bind: 127.0.0.1, or an address that the settings offer.
    /// Never the unspecified address, which would listen on every network.
    public static func isBindable(_ address: String) -> Bool {
        address == loopback || classify(address) != nil
    }

    /// The addresses of the interfaces that are up now, Tailscale first, then IPv4 before IPv6.
    public static func current() -> [ListenAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }
        var found: [ListenAddress] = []
        for entry in sequence(first: head, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let sockaddr = entry.pointee.ifa_addr, let text = IPLiteral.string(from: sockaddr)
            else { continue }
            let interface = String(cString: entry.pointee.ifa_name)
            guard let kind = offerable(text, interface: interface) else { continue }
            let address = ListenAddress(address: text, interface: interface, kind: kind)
            if !found.contains(where: { $0.address == address.address }) { found.append(address) }
        }
        return sort(found)
    }

    static func sort(_ addresses: [ListenAddress]) -> [ListenAddress] {
        addresses.sorted { a, b in
            let rank = { (x: ListenAddress) in (x.kind == .tailscale ? 0 : 1, x.address.contains(":") ? 1 : 0) }
            return rank(a) != rank(b) ? rank(a) < rank(b) : (a.interface, a.address) < (b.interface, b.address)
        }
    }

    /// The address to bind: the chosen one while this Mac has it, and 127.0.0.1 while it does not,
    /// for example while its interface is down. The chosen one comes back when it returns.
    public static func effective(chosen: String, available: [String]) -> (address: String, fellBack: Bool) {
        if chosen == loopback || available.contains(chosen) { return (chosen, false) }
        return (loopback, true)
    }
}

/// IPv4 and IPv6 literals, as text and as bytes.
public enum IPLiteral {
    /// The one text form of an address, or nil if the text is no IP literal. An IPv6 address comes
    /// out compressed and in lower case, as browsers write it in Host and Origin headers. A scope
    /// ("%en0") is not accepted.
    public static func canonical(_ text: String) -> String? {
        if let bytes = ipv4Bytes(text) { return format(bytes, family: AF_INET) }
        if let bytes = ipv6Bytes(text) { return format(bytes, family: AF_INET6) }
        return nil
    }

    /// The form inside a URL: an IPv6 address in brackets.
    public static func urlHost(_ address: String) -> String {
        address.contains(":") ? "[\(address)]" : address
    }

    // inet_pton on macOS takes a scope ("%en0") and drops it, so a scope is refused before it.
    static func ipv4Bytes(_ text: String) -> [UInt8]? {
        guard !text.contains("%") else { return nil }
        var addr = in_addr()
        guard inet_pton(AF_INET, text, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    static func ipv6Bytes(_ text: String) -> [UInt8]? {
        guard !text.contains("%") else { return nil }
        var addr = in6_addr()
        guard inet_pton(AF_INET6, text, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    private static func format(_ bytes: [UInt8], family: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let ok = bytes.withUnsafeBytes { inet_ntop(family, $0.baseAddress, &buffer, socklen_t(buffer.count)) } != nil
        return ok ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
    }

    /// The address of an interface entry, in canonical form. nil for other families.
    static func string(from sockaddr: UnsafeMutablePointer<sockaddr>) -> String? {
        switch Int32(sockaddr.pointee.sa_family) {
        case AF_INET:
            let bytes = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in
                withUnsafeBytes(of: p.pointee.sin_addr) { Array($0) }
            }
            return format(bytes, family: AF_INET)
        case AF_INET6:
            let bytes = sockaddr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                withUnsafeBytes(of: p.pointee.sin6_addr) { Array($0) }
            }
            return format(bytes, family: AF_INET6)
        default:
            return nil
        }
    }
}

/// Moves both listeners to an address: at launch, after a change in the settings, and when the
/// chosen address goes or comes back.
public enum ListenMove {
    /// The waits between tries. A new IPv6 address cannot be bound for a moment after its
    /// interface comes up, and a port can still be held by the listener before.
    public static let retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]

    public enum Outcome: Equatable, Sendable {
        /// Both listeners are ready on `address`, with `token`.
        case moved(address: String, token: AccessToken)
        /// The address kept failing, and both listeners are ready on 127.0.0.1, with `token`.
        case fellBack(token: AccessToken, reason: String)
        /// Not even 127.0.0.1 worked. No listener runs.
        case failed(reason: String)
        case cancelled
    }

    /// `bind` starts both listeners on an address with a token. It returns nil once both are
    /// ready, or the reason of a failure after it has stopped what it started. The move runs on the
    /// caller's actor, so `bind` can start the caller's listeners.
    /// Each move gets a new token, also a move back: another local user can bind the old address
    /// and port later, and then a link with the old token must be of no use.
    public static func run(to target: String,
                           bind: (String, AccessToken) async -> String?,
                           sleep: (Duration) async throws -> Void,
                           makeToken: () -> AccessToken = AccessToken.generate,
                           isolation: isolated (any Actor)? = #isolation) async -> Outcome {
        let token = makeToken()
        var reason = ""
        for attempt in 0...retryDelays.count {
            if attempt > 0 {
                do { try await sleep(retryDelays[attempt - 1]) } catch { return .cancelled }
            }
            guard !Task.isCancelled else { return .cancelled }
            guard let failure = await bind(target, token) else { return .moved(address: target, token: token) }
            reason = failure
        }
        guard target != ListenAddress.loopback else { return .failed(reason: reason) }
        guard !Task.isCancelled else { return .cancelled }
        if let failure = await bind(ListenAddress.loopback, token) { return .failed(reason: failure) }
        return .fellBack(token: token, reason: reason)
    }

    public static let readyTimeout: Duration = .seconds(5)

    /// nil once both listeners report ready, or the reason that one failed or waits. `control` tells
    /// which listener a state is from.
    public static func waitUntilReady(_ states: AsyncStream<(control: Bool, state: ListenerState)>,
                                      timeout: Duration = readyTimeout) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                var ready: Set<Bool> = []
                for await (isControl, state) in states {
                    switch state {
                    case .ready:
                        ready.insert(isControl)
                        if ready.count == 2 { return nil }
                    // A listener that waits has no address to bind, such as an IPv6 address that is not ready yet.
                    case let .failed(message), let .waiting(message):
                        return message
                    case .stopped:
                        break
                    }
                }
                return "The listeners stopped."
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return "The listeners did not start within \(timeout)."
            }
            let first: String? = await group.next() ?? "The listeners stopped."
            group.cancelAll()
            return first
        }
    }
}
