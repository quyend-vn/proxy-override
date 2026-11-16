import AppKit
import Combine
import Foundation
import ServiceManagement

struct LogLine: Identifiable {
    let id = UUID()
    let time = Date()
    let text: String
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    static let passwordKeys = ["http", "https", "socks"]

    @Published var settings = Settings.load()
    @Published var passwords: [String: String] = Dictionary(
        uniqueKeysWithValues: AppModel.passwordKeys.map { ($0, Keychain.password(for: $0)) })
    @Published private(set) var running = false
    @Published private(set) var systemOverridden = false
    @Published private(set) var lastError: String?
    @Published private(set) var logs: [LogLine] = []
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Per Mac (UserDefaults), never synced itself.
    @Published private(set) var iCloudSync = UserDefaults.standard.bool(forKey: "iCloudSync")
    @Published private(set) var lastSync: CloudConfig.Envelope?
    @Published private(set) var backups: [CloudConfig.Backup] = []

    private let engine = ProxyEngine()
    private var bag = Set<AnyCancellable>()
    /// The settings last pushed to or pulled from iCloud: only a local change
    /// away from these is pushed, so two Macs never bounce the same copy back.
    private var syncedSettings: Settings?
    private var syncTimer: Timer?

    private init() {
        engine.log = { [weak self] line in
            DispatchQueue.main.async { self?.appendLog(line) }
        }
        engine.onStateChange = { [weak self] error in
            DispatchQueue.main.async { self?.listenerChanged(error) }
        }
        $settings.dropFirst().removeDuplicates()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] s in
                s.save()
                self?.reapply()
                self?.pushIfChanged(s)
            }
            .store(in: &bag)
        $passwords.dropFirst().removeDuplicates()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] p in
                for (k, v) in p { Keychain.setPassword(v, for: k) }
                self?.reapply()
            }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.pullIfNewer() }
            .store(in: &bag)
    }

    var statusText: String {
        if let lastError { return "Error: \(lastError)" }
        guard running else { return "Stopped" }
        return "Listening on 127.0.0.1:\(settings.listenPort)" + (systemOverridden ? " · macOS proxy overridden" : "")
    }

    // MARK: lifecycle

    func launched() {
        if SystemProxy.hasBackup {
            // left over from a crash: put the user's proxy settings back first
            if let leftovers = try? SystemProxy.restore(ownPort: settings.listenPort) {
                appendLog("recovered from an unclean exit")
                logRestore(leftovers)
            }
        }
        if iCloudSync { startSyncing(adoptRemote: true) }
        if settings.overrideSystemProxy {
            setSystemOverride(true)
        } else if settings.startOnLaunch {
            start()
        }
    }

    func shutdown() {
        engine.stop()
        if systemOverridden { _ = try? SystemProxy.restore(ownPort: settings.listenPort) }
    }

    func start() {
        do {
            lastError = nil
            try engine.start(settings.runtime(passwords: passwords))
            running = true
            appendLog("started on 127.0.0.1:\(settings.listenPort)")
        } catch {
            fail(error)
        }
    }

    func stop() {
        setSystemOverride(false)
        engine.stop()
        running = false
        appendLog("stopped")
    }

    func setSystemOverride(_ on: Bool) {
        guard on != systemOverridden else { return }
        do {
            if on {
                if !running { start() }
                guard running else { return }
                try SystemProxy.enable(port: settings.listenPort, mode: settings.systemProxyMode)
                appendLog("macOS proxy → 127.0.0.1:\(settings.listenPort) via \(settings.systemProxyMode == .pac ? "auto-config (PAC)" : "fixed proxy") (\(SystemProxy.networkServices().joined(separator: ", ")))")
            } else {
                logRestore(try SystemProxy.restore(ownPort: settings.listenPort))
            }
            systemOverridden = on
        } catch {
            fail(error)
        }
    }

    func importFromProxyman() {
        do {
            var s = settings
            try ProxymanImport.apply(to: &s)
            settings = s
            appendLog("imported External Proxy settings from Proxyman (enter credentials manually)")
        } catch {
            fail(error)
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            fail(error)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func clearLogs() { logs.removeAll() }

    // MARK: iCloud

    func setICloudSync(_ on: Bool) {
        guard on != iCloudSync else { return }
        if on {
            guard CloudConfig.isAvailable else { return fail(CloudError.unavailable) }
            iCloudSync = true
            UserDefaults.standard.set(true, forKey: "iCloudSync")
            startSyncing(adoptRemote: true)
        } else {
            iCloudSync = false
            UserDefaults.standard.set(false, forKey: "iCloudSync")
            syncTimer?.invalidate()
            syncTimer = nil
            appendLog("iCloud sync off")
        }
    }

    func backUpNow() {
        do {
            try CloudConfig.backup(settings)
            appendLog("settings backed up to iCloud Drive")
        } catch { fail(error) }
        refreshBackups()
    }

    func restore(_ backup: CloudConfig.Backup) {
        guard let s = CloudConfig.settings(in: backup) else {
            return fail(CocoaError(.fileReadCorruptFile))
        }
        // keep what's being replaced, so a restore can itself be undone
        _ = try? CloudConfig.backup(settings, note: "before restore")
        settings = s
        appendLog("settings restored from backup of \(backup.savedAt.formatted()) (\(backup.device))")
        refreshBackups()
    }

    func deleteBackup(_ backup: CloudConfig.Backup) {
        do { try CloudConfig.delete(backup) } catch { fail(error) }
        refreshBackups()
    }

    func refreshBackups() {
        backups = CloudConfig.isAvailable ? CloudConfig.backups() : []
    }

    /// Turning sync on: an existing iCloud copy wins (the local settings are
    /// backed up first); with none yet, this Mac's settings become the copy.
    private func startSyncing(adoptRemote: Bool) {
        if adoptRemote, let remote = CloudConfig.pull() {
            if remote.settings != settings {
                _ = try? CloudConfig.backup(settings, note: "before sync")
                apply(remote)
            } else {
                syncedSettings = remote.settings
                lastSync = remote
            }
        } else {
            pushIfChanged(settings)
        }
        refreshBackups()
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pullIfNewer() }
        }
    }

    private func pullIfNewer() {
        guard iCloudSync, let remote = CloudConfig.pull() else { return }
        // same copy as last seen: compare stamps for equality, not order, so a
        // Mac whose clock is behind still gets picked up
        if let last = lastSync, remote.savedAt == last.savedAt, remote.device == last.device { return }
        if remote.settings == settings {
            syncedSettings = remote.settings
            lastSync = remote
        } else {
            apply(remote)
        }
    }

    private func apply(_ remote: CloudConfig.Envelope) {
        syncedSettings = remote.settings
        lastSync = remote
        settings = remote.settings
        appendLog("settings synced from \(remote.device) (iCloud)")
    }

    private func pushIfChanged(_ s: Settings) {
        guard iCloudSync, s != syncedSettings else { return }
        do {
            let at = try CloudConfig.push(s)
            syncedSettings = s
            lastSync = CloudConfig.Envelope(savedAt: at, device: CloudConfig.deviceName, settings: s)
        } catch {
            fail(error)
        }
    }

    private func logRestore(_ leftovers: [String]) {
        if leftovers.isEmpty {
            appendLog("macOS proxy restored exactly")
        } else {
            appendLog("macOS proxy restored; still different (switched off, can't be deleted without admin): \(leftovers.joined(separator: ", "))")
        }
    }

    // MARK: private

    /// Settings changed while running: restart the listener with the new config.
    private func reapply() {
        guard running else { return }
        let wasOverridden = systemOverridden
        engine.stop()
        start()
        if wasOverridden && running {
            try? SystemProxy.enable(port: settings.listenPort, mode: settings.systemProxyMode)
        }
    }

    private func listenerChanged(_ error: Error?) {
        guard let error else { return }
        running = false
        if systemOverridden {
            _ = try? SystemProxy.restore(ownPort: settings.listenPort)
            systemOverridden = false
        }
        fail(error)
    }

    private func fail(_ error: Error) {
        lastError = error.localizedDescription
        appendLog("error: \(error.localizedDescription)")
    }

    private func appendLog(_ text: String) {
        logs.append(LogLine(text: text))
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }
    }
}
