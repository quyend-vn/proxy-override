import Foundation
import SystemConfiguration

/// Settings sync and backups through iCloud Drive. Uses the plain iCloud Drive
/// folder (~/Library/Mobile Documents/com~apple~CloudDocs/ProxyOverride), which
/// any app signed in to the user's account can use - CloudKit and iCloud
/// Keychain would need an Apple Developer signing identity. Passwords are never
/// written here; they stay in each Mac's Keychain.
enum CloudConfig {
    /// What's stored in iCloud Drive: the settings plus who saved them and when.
    struct Envelope: Codable {
        var savedAt: Date
        var device: String
        var note: String?
        var settings: Settings
    }

    struct Backup: Identifiable, Hashable {
        var url: URL
        var savedAt: Date
        var device: String
        var note: String?
        var id: URL { url }
    }

    static let maxBackups = 30

    static let driveRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    static let folder = driveRoot.appendingPathComponent("ProxyOverride", isDirectory: true)
    static let currentURL = folder.appendingPathComponent("settings.json")
    static let backupsFolder = folder.appendingPathComponent("Backups", isDirectory: true)

    /// iCloud Drive is turned on for this Mac.
    static var isAvailable: Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: driveRoot.path, isDirectory: &dir) && dir.boolValue
    }

    static var deviceName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName
    }

    // MARK: sync file

    /// Writes the settings as the current synced copy and returns its timestamp.
    @discardableResult
    static func push(_ settings: Settings) throws -> Date {
        let env = Envelope(savedAt: Date(), device: deviceName, settings: settings)
        try write(env, to: currentURL)
        return env.savedAt
    }

    /// The synced copy, or nil if there is none (or it's still downloading).
    static func pull() -> Envelope? {
        read(currentURL)
    }

    // MARK: backups

    @discardableResult
    static func backup(_ settings: Settings, note: String? = nil) throws -> URL {
        let env = Envelope(savedAt: Date(), device: deviceName, note: note, settings: settings)
        let stamp = env.savedAt.formatted(.iso8601.year().month().day().dateSeparator(.dash)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted))
        var name = "\(stamp) \(env.device)"
        if let note { name += " (\(note))" }
        let url = backupsFolder.appendingPathComponent(safeFileName(name) + ".json")
        try write(env, to: url)
        prune()
        return url
    }

    /// Newest first. Backups that are only in iCloud are asked to download and
    /// show up on a later call.
    static func backups() -> [Backup] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: backupsFolder, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.lastPathComponent.hasPrefix(".") && f.pathExtension == "icloud" {
            // ".name.json.icloud" placeholder → ask for "name.json"
            let real = String(f.deletingPathExtension().lastPathComponent.dropFirst())
            try? FileManager.default.startDownloadingUbiquitousItem(at: backupsFolder.appendingPathComponent(real))
        }
        return files.filter { $0.pathExtension == "json" }
            .compactMap { url in read(url).map { Backup(url: url, savedAt: $0.savedAt, device: $0.device, note: $0.note) } }
            .sorted { $0.savedAt > $1.savedAt }
    }

    static func settings(in backup: Backup) -> Settings? {
        read(backup.url)?.settings
    }

    static func delete(_ backup: Backup) throws {
        try FileManager.default.removeItem(at: backup.url)
    }

    private static func prune() {
        for old in backups().dropFirst(maxBackups) {
            try? FileManager.default.removeItem(at: old.url)
        }
    }

    // MARK: files

    private static func write(_ env: Envelope, to url: URL) throws {
        guard isAvailable else { throw CloudError.unavailable }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(env)
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { u in
            do { try data.write(to: u, options: .atomic) } catch { writeError = error }
        }
        if let e = coordError ?? writeError { throw e }
    }

    private static func read(_ url: URL) -> Envelope? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            // evicted by "Optimize Mac Storage": iCloud leaves a .name.icloud placeholder
            let placeholder = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).icloud")
            if fm.fileExists(atPath: placeholder.path) { try? fm.startDownloadingUbiquitousItem(at: url) }
            return nil
        }
        var data: Data?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            data = try? Data(contentsOf: u)
        }
        guard let data else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Envelope.self, from: data)
    }

    private static func safeFileName(_ s: String) -> String {
        String(s.map { "/:\\".contains($0) ? "-" : $0 })
    }
}

enum CloudError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        "iCloud Drive is off. Turn it on in System Settings → Apple Account → iCloud → iCloud Drive."
    }
}
