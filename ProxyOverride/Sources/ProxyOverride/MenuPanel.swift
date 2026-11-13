import AppKit
import SwiftUI

/// The panel shown when clicking the menu bar icon.
struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = model.lastError {
                errorBanner(error)
            }
            Divider()
            VStack(spacing: 12) {
                ToggleRow(
                    icon: "power",
                    tint: .blue,
                    title: "Proxy Running",
                    subtitle: model.running
                        ? "Listening on 127.0.0.1:\(model.settings.listenPort)"
                        : "Local proxy is off",
                    isOn: Binding(get: { model.running },
                                  set: { $0 ? model.start() : model.stop() }))
                ToggleRow(
                    icon: "desktopcomputer",
                    tint: .green,
                    title: "Override macOS Proxy",
                    subtitle: model.systemOverridden
                        ? "System traffic goes through the app"
                        : "macOS uses its own proxy settings",
                    isOn: Binding(get: { model.systemOverridden },
                                  set: { model.setSystemOverride($0) }))
            }
            .padding(14)
            Divider()
            routing
            Divider()
            activity
            Divider()
            footer
        }
        .frame(width: 330)
    }

    // MARK: header

    private var status: (text: String, color: Color) {
        if model.lastError != nil { return ("Error", .red) }
        if model.systemOverridden { return ("Active", .green) }
        if model.running { return ("Running", .blue) }
        return ("Off", .secondary)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "network.badge.shield.half.filled")
                .font(.system(size: 20))
                .foregroundStyle(status.color == .secondary ? Color.secondary : status.color)
            Text("Proxy Override")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(status.color).frame(width: 7, height: 7)
                Text(status.text).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(status.color.opacity(0.14)))
            .foregroundStyle(status.color)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.1)))
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // MARK: routing

    private var routing: some View {
        let rt = model.settings.runtime(passwords: model.passwords)
        let scope = model.settings.include.isEmpty
            ? "All hosts"
            : "\(model.settings.include.count) hosts via proxy"
        let bypass = model.settings.bypass.isEmpty ? "" : " · \(model.settings.bypass.count) bypassed"
        return VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Routing")
            RouteRow(label: "HTTP", value: rt.httpUpstream?.description)
            RouteRow(label: "HTTPS", value: rt.httpsUpstream?.description)
            HStack {
                Text("Scope").foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                Text(scope + bypass)
                Spacer()
            }
            .font(.system(size: 12))
        }
        .padding(14)
    }

    // MARK: activity

    private var activity: some View {
        let recent = model.logs.reversed().prefix(5)
        return VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Recent")
            if recent.isEmpty {
                Text("No connections yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(recent)) { ActivityRow(line: $0) }
            }
        }
        .padding(14)
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            Button {
                openWindow(id: "main")
                NSApp.activate()
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

private struct ToggleRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : Color.secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(isOn ? tint : Color.secondary.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        .contentShape(Rectangle())
    }
}

private struct RouteRow: View {
    let label: String
    let value: String?

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            if let value {
                Text(value).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            } else {
                Text("Direct").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.system(size: 12))
    }
}

/// Turns an engine log line ("CONNECT  host:443 → upstream", "! host:443: error")
/// into a compact host + badge row.
private struct ActivityRow: View {
    let line: LogLine

    private var parsed: (host: String, badge: String, color: Color) {
        let text = line.text
        if text.hasPrefix("! ") {
            let rest = text.dropFirst(2)
            let host = rest.range(of: ": ").map { String(rest[..<$0.lowerBound]) } ?? String(rest)
            return (host, "FAILED", .red)
        }
        if let arrow = text.range(of: " → ") {
            let host = text[..<arrow.lowerBound].split(separator: " ").last.map(String.init) ?? text
            let direct = text[arrow.upperBound...] == "DIRECT"
            return (host, direct ? "DIRECT" : "PROXY", direct ? .secondary : .blue)
        }
        return (text, "", .secondary)
    }

    var body: some View {
        let p = parsed
        HStack(spacing: 6) {
            Circle().fill(p.color).frame(width: 5, height: 5)
            Text(p.host)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if !p.badge.isEmpty {
                Text(p.badge)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(p.color.opacity(0.15)))
                    .foregroundStyle(p.color)
            }
        }
        .help(line.text)
    }
}
