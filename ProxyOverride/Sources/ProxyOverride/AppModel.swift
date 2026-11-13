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

    private let engine = ProxyEngine()
    private var bag = Set<AnyCancellable>()

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
            }
            .store(in: &bag)
        $passwords.dropFirst().removeDuplicates()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] p in
                for (k, v) in p { Keychain.setPassword(v, for: k) }
                self?.reapply()
            }
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
