import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // kill, Ctrl-C, logout: quit through AppKit so applicationWillTerminate
        // restores the macOS proxy (SIGKILL can't be caught - PAC mode covers that)
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
        MainActor.assumeIsolated { AppModel.shared.launched() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
    }
}

struct ProxyOverrideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            Image(systemName: model.systemOverridden ? "network.badge.shield.half.filled" : "network")
                .opacity(model.running ? 1 : 0.5)
        }
        .menuBarExtraStyle(.window)
        Window("Proxy Override", id: "main") {
            MainView().environmentObject(model)
        }
        .defaultLaunchBehavior(.suppressed)
    }
}

/// `ProxyOverride --headless [--config settings.json]`: run only the proxy
/// engine, logging to stdout (passwords come from the Keychain).
func runHeadless() -> Never {
    let args = CommandLine.arguments
    var settings = Settings.load()
    if let i = args.firstIndex(of: "--config"), i + 1 < args.count {
        settings = Settings.load(from: URL(fileURLWithPath: args[i + 1]))
    }
    let passwords = Dictionary(uniqueKeysWithValues: ["http", "https", "socks"].map { ($0, Keychain.password(for: $0)) })
    let config = settings.runtime(passwords: passwords)
    let engine = ProxyEngine()
    engine.log = { print($0); fflush(stdout) }
    engine.onStateChange = { error in
        if let error {
            print("listener failed: \(error)")
            exit(1)
        }
        print("listening on 127.0.0.1:\(config.listenPort)")
        print("  http  → \(config.httpUpstream?.description ?? "direct")")
        print("  https → \(config.httpsUpstream?.description ?? "direct")")
        fflush(stdout)
    }
    do { try engine.start(config) } catch {
        print("failed: \(error)")
        exit(1)
    }
    signal(SIGINT) { _ in exit(0) }
    signal(SIGTERM) { _ in exit(0) }
    dispatchMain()
}

if CommandLine.arguments.contains("--headless") {
    runHeadless()
} else {
    ProxyOverrideApp.main()
}
