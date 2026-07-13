import SwiftUI
import AppKit
import MixerCore

struct RunningApp: Identifiable, Hashable {
    let id: String   // bundle id
    let name: String
}

func runningApps() -> [RunningApp] {
    var seen = Set<String>()
    return NSWorkspace.shared.runningApplications
        .compactMap { app -> RunningApp? in
            guard app.activationPolicy == .regular, let bid = app.bundleIdentifier else { return nil }
            guard seen.insert(bid).inserted else { return nil }
            return RunningApp(id: bid, name: app.localizedName ?? bid)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

struct MenuContentView: View {
    @ObservedObject var engine: RouteEngine

    @State private var apps: [RunningApp] = []
    @State private var devices: [AudioDeviceInfo] = []
    @State private var selectedBundle: String = ""
    @State private var selectedDeviceUID: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform")
                Text("Audio Router").font(.headline)
                Spacer()
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh app & device lists")
            }

            Divider()

            if engine.rules.isEmpty {
                Text("No routes yet. Add one below.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(engine.rules) { rule in
                    ruleRow(rule)
                }
            }

            Divider()

            addRuleForm

            Divider()

            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear(perform: refresh)
    }

    // MARK: Rule row

    @ViewBuilder
    private func ruleRow(_ rule: RoutingRule) -> some View {
        let status = engine.statuses[rule.id] ?? .inactive
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(rule.appName).fontWeight(.medium)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                    Text(rule.deviceName).foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    Circle().fill(statusColor(status)).frame(width: 7, height: 7)
                    Text(status.label).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { engine.setEnabled(rule.id, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            Button {
                engine.remove(rule.id)
            } label: {
                Image(systemName: "trash").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 3)
    }

    private func statusColor(_ s: RouteStatus) -> Color {
        switch s {
        case .active: return .green
        case .waiting: return .orange
        case .error: return .red
        case .inactive: return .gray
        }
    }

    // MARK: Add rule

    private var addRuleForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add route").font(.subheadline).fontWeight(.semibold)
            HStack {
                Picker("App", selection: $selectedBundle) {
                    Text("Choose app…").tag("")
                    ForEach(apps) { app in Text(app.name).tag(app.id) }
                }
                .labelsHidden()
            }
            HStack {
                Picker("Output", selection: $selectedDeviceUID) {
                    Text("Choose output…").tag("")
                    ForEach(devices) { dev in Text(dev.name).tag(dev.uid) }
                }
                .labelsHidden()
            }
            Button {
                addRule()
            } label: {
                Label("Add route", systemImage: "plus")
            }
            .disabled(selectedBundle.isEmpty || selectedDeviceUID.isEmpty)
        }
    }

    // MARK: Actions

    private func refresh() {
        apps = runningApps()
        devices = listOutputDevices()
    }

    private func addRule() {
        guard let app = apps.first(where: { $0.id == selectedBundle }),
              let dev = devices.first(where: { $0.uid == selectedDeviceUID }) else { return }
        engine.add(RoutingRule(appName: app.name, appBundleID: app.id,
                               deviceName: dev.name, deviceUID: dev.uid, enabled: true))
        selectedBundle = ""
        selectedDeviceUID = ""
    }
}
