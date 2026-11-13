import Foundation

/// Reads Proxyman's saved External Proxy settings. Proxyman stores the proxy
/// credentials encrypted, so usernames/passwords are not imported.
enum ProxymanImport {
    static let settingsFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.proxyman.NSProxy/user-data/ExternalProxySetting")

    static var isAvailable: Bool { FileManager.default.fileExists(atPath: settingsFile.path) }

    private struct Entry: Decodable {
        var kind: String
        var host: String?
        var port: Int?
        var isEnabled: Bool?
        var isRequireAuth: Bool?
    }

    static func apply(to s: inout Settings) throws {
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: settingsFile))
        for e in entries {
            var slot = ProxySlot(enabled: e.isEnabled ?? false, host: e.host ?? "", port: e.port ?? 0,
                                 requireAuth: e.isRequireAuth ?? false)
            switch e.kind {
            case "http":
                slot.username = s.http.username
                s.http = slot
            case "https":
                slot.username = s.https.username
                s.https = slot
            case "socks":
                slot.username = s.socks.username
                s.socks = slot
            default:
                break
            }
        }
        let prefs = UserDefaults(suiteName: "com.proxyman.NSProxy")
        let list = { (key: String) in
            (prefs?.string(forKey: key) ?? "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        s.include = list("ExternalProxy-IncludeList")
        s.bypass = list("ByPassProxy-externalProxy")
        if let v = prefs?.object(forKey: "isBypassLocalhostExternalProxy") as? Bool {
            s.bypassLocalhost = v
        }
    }
}
