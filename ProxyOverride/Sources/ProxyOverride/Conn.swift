import Foundation
import Network

enum ConnError: LocalizedError {
    case closed
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .closed: return "connection closed"
        case .protocolError(let m): return m
        }
    }
}

private final class Once {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

/// async/await wrapper around NWConnection with a small read buffer.
final class Conn: @unchecked Sendable {
    let nw: NWConnection
    private let queue = DispatchQueue(label: "ProxyOverride.conn")
    private var buffer = Data()
    private var eof = false

    init(_ nw: NWConnection) { self.nw = nw }

    /// Outbound TCP (optionally TLS) connection that never goes through the
    /// system proxy - otherwise we would loop back into ourselves.
    static func connect(host: String, port: Int, tls: Bool = false, insecure: Bool = false) async throws -> Conn {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else {
            throw ConnError.protocolError("invalid port \(port)")
        }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 15
        tcp.noDelay = true
        var tlsOptions: NWProtocolTLS.Options?
        if tls {
            let t = NWProtocolTLS.Options()
            if insecure {
                sec_protocol_options_set_verify_block(t.securityProtocolOptions, { _, _, done in done(true) }, .global())
            }
            tlsOptions = t
        }
        let params = NWParameters(tls: tlsOptions, tcp: tcp)
        params.preferNoProxies = true
        let c = Conn(NWConnection(host: NWEndpoint.Host(host), port: p, using: params))
        try await c.start()
        return c
    }

    func start() async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nw.stateUpdateHandler = { [nw] state in
                switch state {
                case .ready:
                    if once.fire() { cont.resume() }
                case .failed(let e):
                    if once.fire() { cont.resume(throwing: e) }
                case .waiting(let e):
                    if once.fire() { nw.cancel(); cont.resume(throwing: e) }
                case .cancelled:
                    if once.fire() { cont.resume(throwing: ConnError.closed) }
                default:
                    break
                }
            }
            nw.start(queue: queue)
        }
    }

    private func receiveChunk() async throws -> Data? {
        if eof { return nil }
        return try await withCheckedThrowingContinuation { cont in
            nw.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                if let data, !data.isEmpty {
                    if complete { self.eof = true }
                    cont.resume(returning: data)
                } else if let error {
                    cont.resume(throwing: error)
                } else {
                    self.eof = true
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// Next available bytes (buffered first), nil on EOF.
    func readSome() async throws -> Data? {
        if !buffer.isEmpty {
            let d = buffer
            buffer = Data()
            return d
        }
        return try await receiveChunk()
    }

    func readExactly(_ n: Int) async throws -> Data {
        while buffer.count < n {
            guard let d = try await receiveChunk() else { throw ConnError.closed }
            buffer.append(d)
        }
        let out = Data(buffer.prefix(n))
        buffer = Data(buffer.dropFirst(n))
        return out
    }

    /// Reads up to the blank line ending an HTTP header block; the bytes after
    /// it stay buffered for the next read.
    func readHead(limit: Int = 65536) async throws -> Data {
        let sep = Data("\r\n\r\n".utf8)
        while true {
            if let r = buffer.range(of: sep) {
                let head = Data(buffer[buffer.startIndex..<r.lowerBound])
                buffer = Data(buffer[r.upperBound...])
                return head
            }
            if buffer.count > limit { throw ConnError.protocolError("header too large") }
            guard let d = try await receiveChunk() else { throw ConnError.closed }
            buffer.append(d)
        }
    }

    func unread(_ d: Data) {
        buffer = d + buffer
    }

    func write(_ d: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nw.send(content: d, completion: .contentProcessed { e in
                if let e { cont.resume(throwing: e) } else { cont.resume() }
            })
        }
    }

    func write(_ s: String) async throws {
        try await write(Data(s.utf8))
    }

    func writeEOF() {
        nw.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
    }

    func cancel() {
        nw.cancel()
    }
}

/// Copies bytes both ways until both directions are finished.
func relay(_ a: Conn, _ b: Conn) async {
    func pipe(_ src: Conn, _ dst: Conn) async {
        do {
            while let d = try await src.readSome() {
                try await dst.write(d)
            }
            dst.writeEOF()
        } catch {
            // a reset on one side would otherwise leave the other read pending forever
            src.cancel()
            dst.cancel()
        }
    }
    await withTaskGroup(of: Void.self) { g in
        g.addTask { await pipe(a, b) }
        g.addTask { await pipe(b, a) }
    }
    a.cancel()
    b.cancel()
}
