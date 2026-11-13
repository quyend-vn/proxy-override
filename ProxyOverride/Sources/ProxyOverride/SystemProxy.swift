import Foundation
import SystemConfiguration

/// How the macOS proxy is pointed at the local listener.
enum SystemProxyMode: String, Codable, CaseIterable {
    /// Proxy auto-config served by the app. Fails open: if the app is gone macOS
    /// can't load the PAC (or reach the proxy it names) and connects directly.
    case pac
    /// Fixed Web/Secure Web proxy, like Proxyman. Fails closed: if the app dies
    /// without restoring, every connection goes to a dead port.
    case fixed
}

/// Points the macOS proxy settings of every enabled network service at the local
/// listener. Before changing anything it snapshots the exact values of the keys
/// it manages (read from SystemConfiguration), and restore() writes back only the
/// keys that differ - all other proxy settings (SOCKS, bypass list, ...) are never
/// touched. Changes go through networksetup, which needs no admin password.
enum SystemProxy {
    private static let backupURL = Settings.directory.appendingPathComponent("system-proxy-backup.json")

    /// The only keys of a service's proxy settings this app ever changes.
    static let managedKeys = ["HTTPEnable", "HTTPProxy", "HTTPPort",
                              "HTTPSEnable", "HTTPSProxy", "HTTPSPort",
                              "ProxyAutoConfigEnable", "ProxyAutoConfigURLString"]

    /// service name → managed key → value; a missing key was absent.
    typealias Snapshot = [String: [String: String]]

    static var hasBackup: Bool { FileManager.default.fileExists(atPath: backupURL.path) }

    static func pacURL(port: Int) -> String {
        // a new query string each time makes macOS fetch the rules again
        "http://127.0.0.1:\(port)/proxy.pac?v=\(Int(Date().timeIntervalSince1970))"
    }

    static func enable(port: Int, mode: SystemProxyMode) throws {
        let services = networkServices()
        if !hasBackup {
            let now = read()
            var snapshot: Snapshot = [:]
            for svc in services {
                snapshot[svc] = sanitized(now[svc] ?? [:], ownPort: port)
            }
            try JSONEncoder().encode(snapshot).write(to: backupURL, options: .atomic)
        }
        var cmds: [[String]] = []
        for svc in services {
            switch mode {
            case .pac:
                cmds.append(["-setautoproxyurl", svc, pacURL(port: port)])
                cmds.append(["-setautoproxystate", svc, "on"])
                cmds.append(["-setwebproxystate", svc, "off"])
                cmds.append(["-setsecurewebproxystate", svc, "off"])
            case .fixed:
                for k in ["webproxy", "securewebproxy"] {
                    cmds.append(["-set\(k)", svc, "127.0.0.1", String(port)])
                    cmds.append(["-set\(k)state", svc, "on"])
                }
                cmds.append(["-setautoproxystate", svc, "off"])
            }
        }
        try run(cmds)
    }

    /// Puts the snapshot back and returns the keys that still differ afterwards
    /// ("service: key") - networksetup can overwrite a value but not delete a key
    /// that didn't exist before, so such a key stays, switched off.
    @discardableResult
    static func restore(ownPort: Int) throws -> [String] {
        guard let snapshot = loadBackup() else { return [] }
        let now = read()
        var cmds: [[String]] = []
        for (svc, saved) in snapshot {
            guard let cur = now[svc] else { continue }   // service no longer exists
            let orig = sanitized(saved, ownPort: ownPort)
            for (prefix, kind) in [("HTTP", "webproxy"), ("HTTPS", "securewebproxy")] {
                var touched = false
                if let host = orig["\(prefix)Proxy"], let port = orig["\(prefix)Port"],
                   cur["\(prefix)Proxy"] != host || cur["\(prefix)Port"] != port {
                    cmds.append(["-set\(kind)", svc, host, port])   // also switches it on
                    touched = true
                }
                let wantOn = orig["\(prefix)Enable"] == "1"
                if touched || (cur["\(prefix)Enable"] == "1") != wantOn {
                    cmds.append(["-set\(kind)state", svc, wantOn ? "on" : "off"])
                }
            }
            var touched = false
            if let url = orig["ProxyAutoConfigURLString"], cur["ProxyAutoConfigURLString"] != url {
                cmds.append(["-setautoproxyurl", svc, url])
                touched = true
            }
            let wantOn = orig["ProxyAutoConfigEnable"] == "1"
            if touched || (cur["ProxyAutoConfigEnable"] == "1") != wantOn {
                cmds.append(["-setautoproxystate", svc, wantOn ? "on" : "off"])
            }
        }
        try run(cmds)
        try? FileManager.default.removeItem(at: backupURL)

        let after = read()
        var leftovers: [String] = []
        for (svc, saved) in snapshot {
            guard let cur = after[svc] else { continue }
            let orig = sanitized(saved, ownPort: ownPort)
            for key in managedKeys where !sameValue(key, orig[key], cur[key]) {
                leftovers.append("\(svc): \(key)")
            }
        }
        return leftovers.sorted()
    }

    static func networkServices() -> [String] {
        networksetup(["-listallnetworkservices"]).output
            .split(separator: "\n").dropFirst()
            .map(String.init)
            .filter { !$0.isEmpty && !$0.hasPrefix("*") }
    }

    /// Managed proxy keys of every enabled service, exactly as stored by macOS.
    static func read() -> Snapshot {
        guard let prefs = SCPreferencesCreate(nil, "ProxyOverride" as CFString, nil),
              let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else { return [:] }
        var out: Snapshot = [:]
        for svc in services where SCNetworkServiceGetEnabled(svc) {
            guard let name = SCNetworkServiceGetName(svc) as String? else { continue }
            let config = SCNetworkServiceCopyProtocol(svc, kSCNetworkProtocolTypeProxies)
                .flatMap { SCNetworkProtocolGetConfiguration($0) } as? [String: Any] ?? [:]
            var values: [String: String] = [:]
            for key in managedKeys {
                if let v = config[key] { values[key] = "\(v)" }
            }
            out[name] = values
        }
        return out
    }

    /// A saved value pointing at our own listener comes from a run that was killed
    /// before it could restore: treat it as switched off, never restore it as on.
    private static func sanitized(_ values: [String: String], ownPort: Int) -> [String: String] {
        let local = ["127.0.0.1", "localhost", "::1"]
        var v = values
        for prefix in ["HTTP", "HTTPS"] {
            if let host = v["\(prefix)Proxy"], local.contains(host), v["\(prefix)Port"] == String(ownPort) {
                v["\(prefix)Enable"] = "0"
            }
        }
        if let url = v["ProxyAutoConfigURLString"], local.contains(where: { url.hasPrefix("http://\($0):\(ownPort)/") }) {
            v["ProxyAutoConfigEnable"] = "0"
        }
        return v
    }

    /// An absent Enable flag means off.
    private static func sameValue(_ key: String, _ a: String?, _ b: String?) -> Bool {
        key.hasSuffix("Enable") ? (a ?? "0") == (b ?? "0") : a == b
    }

    private static func loadBackup() -> Snapshot? {
        guard let data = try? Data(contentsOf: backupURL) else { return nil }
        if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            return snapshot
        }
        // backup written by an older build: service → kind → {enabled, server, port}
        struct Entry: Decodable { var enabled: Bool; var server: String; var port: String }
        guard let old = try? JSONDecoder().decode([String: [String: Entry]].self, from: data) else { return nil }
        return old.mapValues { kinds in
            var v: [String: String] = [:]
            for (kind, prefix) in [("webproxy", "HTTP"), ("securewebproxy", "HTTPS")] {
                guard let e = kinds[kind] else { continue }
                v["\(prefix)Enable"] = e.enabled ? "1" : "0"
                if !e.server.isEmpty { v["\(prefix)Proxy"] = e.server; v["\(prefix)Port"] = e.port }
            }
            if let e = kinds["autoproxyurl"] {
                v["ProxyAutoConfigEnable"] = e.enabled ? "1" : "0"
                if !e.server.isEmpty && e.server != "(null)" { v["ProxyAutoConfigURLString"] = e.server }
            }
            return v
        }
    }

    /// Runs the commands as the current user; if networksetup refuses, retries
    /// the whole batch once through an administrator prompt.
    private static func run(_ cmds: [[String]]) throws {
        let failed = cmds.contains { cmd in
            let r = networksetup(cmd)
            return r.status != 0 || r.output.localizedCaseInsensitiveContains("error")
        }
        guard failed else { return }
        let script = cmds.map { (["/usr/sbin/networksetup"] + $0).map(shellQuote).joined(separator: " ") }
            .joined(separator: "; ")
        let apple = "do shell script \"\(script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        let r = exec("/usr/bin/osascript", ["-e", apple])
        if r.status != 0 {
            throw ConnError.protocolError("Changing the system proxy failed: \(r.output)")
        }
    }

    private static func networksetup(_ args: [String]) -> (status: Int32, output: String) {
        exec("/usr/sbin/networksetup", args)
    }

    private static func exec(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
