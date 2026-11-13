import Foundation
import Security

/// One external proxy entry, same three slots as Proxyman (HTTP / HTTPS / SOCKS).
struct ProxySlot: Codable, Equatable {
    var enabled = false
    var host = ""
    var port = 0
    var requireAuth = false
    var username = ""
    var useTLS = false   // HTTP/HTTPS slots only: talk TLS to the proxy itself
}

struct Settings: Codable, Equatable {
    var listenPort = 9090
    var http = ProxySlot()
    var https = ProxySlot()
    var socks = ProxySlot()
    var include: [String] = []
    var bypass: [String] = []
    var bypassLocalhost = true
    var insecureTLS = false
    var startOnLaunch = false
    var overrideSystemProxy = false
    var systemProxyMode = SystemProxyMode.pac

    static let directory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProxyOverride", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static let fileURL = directory.appendingPathComponent("settings.json")

    static func load(from url: URL = fileURL) -> Settings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    func save(to url: URL = Settings.fileURL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: url, options: .atomic)
    }

    /// Resolves the slots into the upstreams the engine routes with. A SOCKS
    /// proxy, when enabled, carries all traffic (like Proxyman).
    func runtime(passwords: [String: String]) -> RuntimeConfig {
        func upstream(_ slot: ProxySlot, key: String, kind: Upstream.Kind) -> Upstream? {
            guard slot.enabled, !slot.host.isEmpty, slot.port > 0 else { return nil }
            return Upstream(kind: kind, host: slot.host, port: slot.port,
                            tls: kind == .http && slot.useTLS, insecure: insecureTLS,
                            username: slot.requireAuth ? slot.username : nil,
                            password: slot.requireAuth ? passwords[key] ?? "" : "")
        }
        let socksUp = upstream(socks, key: "socks", kind: .socks5)
        return RuntimeConfig(
            listenPort: listenPort,
            httpUpstream: socksUp ?? upstream(http, key: "http", kind: .http),
            httpsUpstream: socksUp ?? upstream(https, key: "https", kind: .http),
            include: include.map { $0.lowercased() },
            bypass: bypass.map { $0.lowercased() },
            bypassLocalhost: bypassLocalhost,
            pac: pacScript())
    }

    /// PAC served at /proxy.pac. Only hosts that would use the external proxy are
    /// sent to the app at all, and "; DIRECT" lets clients connect directly when
    /// the app isn't listening, so a dead app never takes the network down.
    func pacScript() -> String {
        let usesUpstream = socks.enabled || http.enabled || https.enabled
        let list = { (hosts: [String]) in
            "[" + hosts.map { "\"" + $0.lowercased().filter { $0 != "\"" && $0 != "\\" } + "\"" }
                .joined(separator: ", ") + "]"
        }
        return #"""
        // ProxyOverride - generated, served from 127.0.0.1:\#(listenPort)
        var include = \#(list(include));
        var bypass = \#(list(bypass));
        var bypassLocal = \#(bypassLocalhost);
        var useProxy = \#(usesUpstream);

        function matches(p, h) {
          return shExpMatch(h, p) || (p.substring(0, 2) == "*." && h == p.substring(2));
        }
        function anyMatch(list, h) {
          for (var i = 0; i < list.length; i++) { if (matches(list[i], h)) return true; }
          return false;
        }
        function isLocal(h) {
          if (isPlainHostName(h) || h == "localhost" || dnsDomainIs(h, ".localhost") || dnsDomainIs(h, ".local")) return true;
          return /^(127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.)/.test(h) || h == "::1" || /^\[?(fe80|fc|fd)/i.test(h);
        }
        function FindProxyForURL(url, host) {
          host = host.toLowerCase();
          if (!useProxy) return "DIRECT";
          if (bypassLocal && isLocal(host)) return "DIRECT";
          if (anyMatch(bypass, host)) return "DIRECT";
          if (include.length && !anyMatch(include, host)) return "DIRECT";
          return "PROXY 127.0.0.1:\#(listenPort); DIRECT";
        }

        """#
    }
}

extension Settings {
    /// Missing keys fall back to defaults, so settings saved by an older build
    /// still load instead of being reset.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        self.init(listenPort: v(.listenPort, d.listenPort),
                  http: v(.http, d.http),
                  https: v(.https, d.https),
                  socks: v(.socks, d.socks),
                  include: v(.include, d.include),
                  bypass: v(.bypass, d.bypass),
                  bypassLocalhost: v(.bypassLocalhost, d.bypassLocalhost),
                  insecureTLS: v(.insecureTLS, d.insecureTLS),
                  startOnLaunch: v(.startOnLaunch, d.startOnLaunch),
                  overrideSystemProxy: v(.overrideSystemProxy, d.overrideSystemProxy),
                  systemProxyMode: v(.systemProxyMode, d.systemProxyMode))
    }
}

enum Keychain {
    private static let service = "ProxyOverride"

    static func password(for account: String) -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    static func setPassword(_ value: String, for account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        if value.isEmpty {
            SecItemDelete(q as CFDictionary)
            return
        }
        let attrs = [kSecValueData as String: Data(value.utf8)]
        if SecItemUpdate(q as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            SecItemAdd(q.merging(attrs) { $1 } as CFDictionary, nil)
        }
    }
}
