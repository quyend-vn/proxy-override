import AppKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            UpstreamTab().tabItem { Label("External Proxy", systemImage: "network") }
            RulesTab().tabItem { Label("Rules", systemImage: "list.bullet") }
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            LogsTab().tabItem { Label("Logs", systemImage: "text.alignleft") }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 520)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Circle().fill(model.running ? Color.green : Color.secondary).frame(width: 8, height: 8)
                Text(model.statusText).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Toggle("Override macOS Proxy", isOn: Binding(
                    get: { model.systemOverridden },
                    set: { model.setSystemOverride($0) }))
                Button(model.running ? "Stop" : "Start") { model.running ? model.stop() : model.start() }
            }
            .padding(.horizontal)
            .padding(.bottom, 10)
        }
    }
}

private struct UpstreamTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            SlotSection(title: "HTTP Proxy", note: "Used for plain http:// traffic.",
                        slot: $model.settings.http, password: password("http"), showTLS: true)
            SlotSection(title: "HTTPS Proxy", note: "Used for https:// traffic (CONNECT tunnels) and SOCKS clients.",
                        slot: $model.settings.https, password: password("https"), showTLS: true)
            SlotSection(title: "SOCKS5 Proxy", note: "When enabled, carries all traffic and overrides the two above.",
                        slot: $model.settings.socks, password: password("socks"), showTLS: false)
        }
        .formStyle(.grouped)
    }

    private func password(_ key: String) -> Binding<String> {
        Binding(get: { model.passwords[key] ?? "" }, set: { model.passwords[key] = $0 })
    }
}

private struct SlotSection: View {
    let title: String
    let note: String
    @Binding var slot: ProxySlot
    @Binding var password: String
    let showTLS: Bool

    var body: some View {
        Section {
            Toggle("Enabled", isOn: $slot.enabled)
            Group {
                TextField("Host", text: $slot.host, prompt: Text("proxy.example.com"))
                TextField("Port", value: $slot.port, format: .number.grouping(.never))
                if showTLS {
                    Toggle("Connect to proxy over TLS", isOn: $slot.useTLS)
                }
                Toggle("Requires authentication", isOn: $slot.requireAuth)
                if slot.requireAuth {
                    TextField("Username", text: $slot.username)
                    SecureField("Password", text: $password)
                }
            }
            .disabled(!slot.enabled)
        } header: {
            Text(title)
        } footer: {
            Text(note).foregroundStyle(.secondary)
        }
    }
}

private struct RulesTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                HostListEditor(list: $model.settings.include)
            } header: {
                Text("Include list")
            } footer: {
                Text("Only these hosts go through the external proxy; everything else connects directly. Leave empty to send all hosts through the proxy. One host per line, wildcards like *.example.com allowed.")
                    .foregroundStyle(.secondary)
            }
            Section {
                HostListEditor(list: $model.settings.bypass)
                Toggle("Bypass localhost and private network addresses", isOn: $model.settings.bypassLocalhost)
            } header: {
                Text("Bypass list")
            } footer: {
                Text("These hosts always connect directly, even if they match the include list.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Free-form editor; keeps its own text so typing a new line isn't normalised away.
private struct HostListEditor: View {
    @Binding var list: [String]
    @State private var text = ""

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 110)
            .onAppear { text = list.joined(separator: "\n") }
            .onChange(of: text) { _, new in
                let parsed = new.split(whereSeparator: { $0 == "\n" || $0 == "," })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if parsed != list { list = parsed }
            }
            .onChange(of: list) { _, new in
                // external change (e.g. import from Proxyman)
                let current = text.split(whereSeparator: { $0 == "\n" || $0 == "," })
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if current != new { text = new.joined(separator: "\n") }
            }
    }
}

private struct GeneralTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Local proxy") {
                TextField("Listen port (127.0.0.1)", value: $model.settings.listenPort, format: .number.grouping(.never))
                Text("Accepts HTTP, HTTPS (CONNECT) and SOCKS5 on the same port.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Picker("Method", selection: $model.settings.systemProxyMode) {
                    Text("Auto-config (PAC) — recommended").tag(SystemProxyMode.pac)
                    Text("Fixed proxy (like Proxyman)").tag(SystemProxyMode.fixed)
                }
            } header: {
                Text("Override macOS Proxy")
            } footer: {
                Text(model.settings.systemProxyMode == .pac
                     ? "Only hosts in the include list are sent to the app. If the app quits or crashes, macOS connects directly, so the Mac never loses internet. Included hosts then also go direct, without the external proxy."
                     : "All web traffic is sent to the app. If the app is force-quit or crashes, the Mac has no internet until the app is opened again.")
                    .foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
                Toggle("Start proxy when the app launches", isOn: $model.settings.startOnLaunch)
                Toggle("Override macOS proxy when the app launches", isOn: $model.settings.overrideSystemProxy)
            }
            Section("Security") {
                Toggle("Skip certificate verification for TLS proxies", isOn: $model.settings.insecureTLS)
            }
            Section {
                Button("Import External Proxy settings from Proxyman") { model.importFromProxyman() }
                    .disabled(!ProxymanImport.isAvailable)
            } footer: {
                Text("Copies hosts, ports, include and bypass lists. Proxyman keeps credentials encrypted, so enter usernames and passwords again.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct LogsTab: View {
    @EnvironmentObject var model: AppModel
    private static let timeFormat = Date.FormatStyle.dateTime.hour().minute().second()

    var body: some View {
        VStack(alignment: .leading) {
            ScrollViewReader { proxy in
                List(model.logs) { line in
                    HStack(alignment: .firstTextBaseline) {
                        Text(line.time, format: Self.timeFormat).foregroundStyle(.secondary)
                        Text(line.text).textSelection(.enabled)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .id(line.id)
                }
                .onChange(of: model.logs.count) { _, _ in
                    if let last = model.logs.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            HStack {
                Spacer()
                Button("Clear") { model.clearLogs() }
            }
        }
    }
}
