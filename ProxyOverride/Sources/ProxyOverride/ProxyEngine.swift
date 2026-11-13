import Darwin
import Foundation
import Network

struct Upstream: CustomStringConvertible {
    enum Kind { case http, socks5 }
    var kind: Kind
    var host: String
    var port: Int
    var tls = false          // only for .http: TLS between us and the proxy
    var insecure = false
    var username: String?
    var password = ""

    var description: String {
        let scheme = kind == .socks5 ? "socks5" : (tls ? "https" : "http")
        return "\(scheme)://\(host):\(port)"
    }

    var proxyAuthorization: String? {
        guard let username, !username.isEmpty else { return nil }
        return "Proxy-Authorization: Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }
}

/// Immutable snapshot the engine routes with.
struct RuntimeConfig {
    var listenPort: Int
    var httpUpstream: Upstream?    // plain http:// requests
    var httpsUpstream: Upstream?   // CONNECT tunnels and SOCKS clients
    var include: [String]
    var bypass: [String]
    var bypassLocalhost: Bool
    var pac = ""

    func route(host: String, plainHTTP: Bool) -> Upstream? {
        guard let up = plainHTTP ? httpUpstream : httpsUpstream else { return nil }
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if bypassLocalhost && isLocalHost(h) { return nil }
        if bypass.contains(where: { hostMatches($0, h) }) { return nil }
        if !include.isEmpty && !include.contains(where: { hostMatches($0, h) }) { return nil }
        return up
    }
}

/// Proxyman-style wildcard: "*.example.com" also matches "example.com".
func hostMatches(_ pattern: String, _ host: String) -> Bool {
    if fnmatch(pattern, host, 0) == 0 { return true }
    return pattern.hasPrefix("*.") && host == String(pattern.dropFirst(2))
}

func isLocalHost(_ h: String) -> Bool {
    if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") { return true }
    var v4 = in_addr()
    if inet_pton(AF_INET, h, &v4) == 1 {
        let b = withUnsafeBytes(of: &v4) { Array($0) }
        return b[0] == 127 || b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1]))
            || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
    }
    var v6 = in6_addr()
    if inet_pton(AF_INET6, h, &v6) == 1 {
        let b = withUnsafeBytes(of: &v6) { Array($0) }
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }   // ::1
        return (b[0] == 0xfe && b[1] & 0xc0 == 0x80) || (b[0] & 0xfe == 0xfc) // fe80::/10, fc00::/7
    }
    return false
}

final class ProxyEngine {
    private var listener: NWListener?
    var log: (String) -> Void = { print($0) }
    /// nil when listening, otherwise the error that stopped the listener.
    var onStateChange: (Error?) -> Void = { _ in }

    func start(_ config: RuntimeConfig) throws {
        stop()
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: config.listenPort)) else {
            throw ConnError.protocolError("invalid listen port")
        }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        let log = self.log
        l.newConnectionHandler = { nw in
            Task { await Session(config: config, log: log).run(Conn(nw)) }
        }
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onStateChange(nil)
            case .failed(let e): self?.onStateChange(e); l.cancel()
            default: break
            }
        }
        l.start(queue: DispatchQueue(label: "ProxyOverride.listener"))
        listener = l
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
    }
}

/// Handles one client connection: HTTP proxy, CONNECT or SOCKS5 on the same port.
private struct Session {
    let config: RuntimeConfig
    let log: (String) -> Void

    func run(_ client: Conn) async {
        do {
            try await client.start()
            let first = try await client.readExactly(1)
            if first.first == 0x05 {
                try await socks(client)
            } else {
                client.unread(first)
                try await http(client)
            }
        } catch {
            log("! \(error.localizedDescription)")
            client.cancel()
        }
    }

    private func socks(_ client: Conn) async throws {
        let nMethods = Int(try await client.readExactly(1)[0])
        _ = try await client.readExactly(nMethods)
        try await client.write(Data([0x05, 0x00]))
        let req = try await client.readExactly(4)
        let host: String
        switch req[3] {
        case 0x01:
            host = try await client.readExactly(4).map(String.init).joined(separator: ".")
        case 0x04:
            host = ipv6String(try await client.readExactly(16))
        case 0x03:
            let len = Int(try await client.readExactly(1)[0])
            host = String(decoding: try await client.readExactly(len), as: UTF8.self)
        default:
            throw ConnError.protocolError("SOCKS5: bad address type")
        }
        let pb = try await client.readExactly(2)
        let port = Int(pb[0]) << 8 | Int(pb[1])
        let failReply = { (code: UInt8) in Data([0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0]) }
        guard req[1] == 0x01 else {
            try await client.write(failReply(0x07))
            client.cancel()
            return
        }
        let up = config.route(host: host, plainHTTP: false)
        log("SOCKS    \(host):\(port) → \(up?.description ?? "DIRECT")")
        let remote: Conn
        do {
            remote = try await openTunnel(host: host, port: port, via: up)
        } catch {
            log("! \(host):\(port): \(error.localizedDescription)")
            try? await client.write(failReply(0x05))
            client.cancel()
            return
        }
        try await client.write(failReply(0x00))
        await relay(client, remote)
    }

    private func http(_ client: Conn) async throws {
        let headData = try await client.readHead()
        guard let head = String(data: headData, encoding: .isoLatin1) else {
            throw ConnError.protocolError("bad request header")
        }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { throw ConnError.protocolError("bad request line") }
        let (method, target, version) = (parts[0], parts[1], parts[2])

        if method.uppercased() == "CONNECT" {
            let (host, port) = splitHostPort(target, defaultPort: 443)
            let up = config.route(host: host, plainHTTP: false)
            log("CONNECT  \(host):\(port) → \(up?.description ?? "DIRECT")")
            let remote: Conn
            do {
                remote = try await openTunnel(host: host, port: port, via: up)
            } catch {
                log("! \(host):\(port): \(error.localizedDescription)")
                try? await client.write("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")
                client.cancel()
                return
            }
            try await client.write("HTTP/1.1 200 Connection Established\r\n\r\n")
            await relay(client, remote)
            return
        }

        if target.hasPrefix("/proxy.pac") {
            let body = Data(config.pac.utf8)
            try await client.write("HTTP/1.1 200 OK\r\nContent-Type: application/x-ns-proxy-autoconfig\r\n"
                                   + "Content-Length: \(body.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n")
            try await client.write(body)
            client.writeEOF()
            while (try? await client.readSome()) != nil {}
            client.cancel()
            return
        }

        guard let url = URLComponents(string: target), url.scheme?.lowercased() == "http",
              let host = url.host, !host.isEmpty else {
            try await client.write("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\nabsolute http:// URL expected\n")
            client.cancel()
            return
        }
        let port = url.port ?? 80
        let up = config.route(host: host, plainHTTP: true)
        log("\(method.padding(toLength: 8, withPad: " ", startingAt: 0)) \(host):\(port) → \(up?.description ?? "DIRECT")")

        // One request per connection keeps per-request routing correct.
        let dropped = ["proxy-connection:", "connection:", "keep-alive:", "proxy-authorization:"]
        var headers = lines.filter { l in !dropped.contains { l.lowercased().hasPrefix($0) } }
        headers.append("Connection: close")

        let remote: Conn
        let requestTarget: String
        do {
            if let up, up.kind == .http {
                remote = try await Conn.connect(host: up.host, port: up.port, tls: up.tls, insecure: up.insecure)
                requestTarget = target
                if let auth = up.proxyAuthorization { headers.append(auth) }
            } else {
                remote = try await openTunnel(host: host, port: port, via: up)
                let path = url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath
                requestTarget = path + (url.percentEncodedQuery.map { "?" + $0 } ?? "")
            }
        } catch {
            log("! \(host):\(port): \(error.localizedDescription)")
            try? await client.write("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")
            client.cancel()
            return
        }
        let request = ([("\(method) \(requestTarget) \(version)")] + headers).joined(separator: "\r\n") + "\r\n\r\n"
        try await remote.write(request.data(using: .isoLatin1) ?? Data(request.utf8))
        await relay(client, remote)
    }

    /// Raw TCP stream to host:port, direct or through the upstream proxy.
    private func openTunnel(host: String, port: Int, via up: Upstream?) async throws -> Conn {
        guard let up else { return try await Conn.connect(host: host, port: port) }
        let c = try await Conn.connect(host: up.host, port: up.port, tls: up.tls, insecure: up.insecure)
        do {
            switch up.kind {
            case .http:
                let hp = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
                var req = "CONNECT \(hp) HTTP/1.1\r\nHost: \(hp)\r\n"
                if let auth = up.proxyAuthorization { req += auth + "\r\n" }
                try await c.write(req + "\r\n")
                let head = String(decoding: try await c.readHead(), as: UTF8.self)
                let status = head.components(separatedBy: "\r\n").first ?? ""
                guard status.split(separator: " ").dropFirst().first == "200" else {
                    throw ConnError.protocolError("upstream refused CONNECT: \(status)")
                }
            case .socks5:
                try await socks5Handshake(c, host: host, port: port, up: up)
            }
            return c
        } catch {
            c.cancel()
            throw error
        }
    }

    private func socks5Handshake(_ c: Conn, host: String, port: Int, up: Upstream) async throws {
        let wantsAuth = !(up.username ?? "").isEmpty
        try await c.write(wantsAuth ? Data([0x05, 0x02, 0x00, 0x02]) : Data([0x05, 0x01, 0x00]))
        let m = try await c.readExactly(2)
        if m[1] == 0x02 {
            let u = Data((up.username ?? "").utf8), p = Data(up.password.utf8)
            try await c.write(Data([0x01, UInt8(u.count)]) + u + Data([UInt8(p.count)]) + p)
            guard try await c.readExactly(2)[1] == 0x00 else {
                throw ConnError.protocolError("SOCKS5 authentication failed")
            }
        } else if m[1] != 0x00 {
            throw ConnError.protocolError("SOCKS5 proxy rejected auth methods")
        }
        var addr = Data()
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            addr = Data([0x01]) + withUnsafeBytes(of: &v4) { Data($0) }
        } else if inet_pton(AF_INET6, host, &v6) == 1 {
            addr = Data([0x04]) + withUnsafeBytes(of: &v6) { Data($0) }
        } else {
            let h = Data(host.utf8)  // remote DNS (socks5h behaviour)
            addr = Data([0x03, UInt8(h.count)]) + h
        }
        try await c.write(Data([0x05, 0x01, 0x00]) + addr + Data([UInt8(port >> 8), UInt8(port & 0xff)]))
        let rep = try await c.readExactly(4)
        guard rep[1] == 0x00 else { throw ConnError.protocolError("SOCKS5 connect failed, code \(rep[1])") }
        let n: Int
        switch rep[3] {
        case 0x01: n = 4
        case 0x04: n = 16
        default: n = Int(try await c.readExactly(1)[0])
        }
        _ = try await c.readExactly(n + 2)
    }
}

func splitHostPort(_ s: String, defaultPort: Int) -> (String, Int) {
    if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
        let host = String(s[s.index(after: s.startIndex)..<close])
        let rest = s[s.index(after: close)...].drop(while: { $0 == ":" })
        return (host, Int(rest) ?? defaultPort)
    }
    if let colon = s.lastIndex(of: ":"), let port = Int(s[s.index(after: colon)...]) {
        return (String(s[..<colon]), port)
    }
    return (s, defaultPort)
}

private func ipv6String(_ b: Data) -> String {
    var addr = in6_addr()
    withUnsafeMutableBytes(of: &addr) { $0.copyBytes(from: b) }
    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    inet_ntop(AF_INET6, &addr, &buf, socklen_t(INET6_ADDRSTRLEN))
    return String(cString: buf)
}
