import SwiftUI
import AppKit
import Combine
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

/// A segmented level meter (activity-monitor style).
struct SegmentMeter: View {
    var level: Float            // raw peak 0…1
    var segments = 8
    var gain: Float = 3.0

    var body: some View {
        let lit = Int((min(1, level * gain)) * Float(segments))
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < lit ? color(for: i) : Color.secondary.opacity(0.18))
                    .frame(width: 4, height: 11)
            }
        }
    }

    private func color(for i: Int) -> Color {
        if i >= segments - 2 { return .red }
        if i >= segments - 4 { return .yellow }
        return .green
    }
}

struct MenuContentView: View {
    @ObservedObject var engine: RouteEngine

    @State private var apps: [RunningApp] = []
    @State private var devices: [AudioDeviceInfo] = []
    @State private var selectedBundle: String = ""
    @State private var selectedDeviceUID: String = ""
    @State private var levels: [UUID: Float] = [:]

    private let ticker = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            activitySection
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
        .frame(width: 380)
        .onAppear(perform: refresh)
        .onReceive(ticker) { _ in
            for rule in engine.rules {
                let v = engine.level(for: rule.id)
                levels[rule.id] = max(v, (levels[rule.id] ?? 0) * 0.75)   // smooth decay
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "waveform")
            Text("Audio Router").font(.headline)
            Spacer()
            Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh app & device lists")
        }
    }

    // MARK: Activity monitor

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ACTIVITY").font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)

            // Default path — where everything un-routed goes.
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Everything else").fontWeight(.medium)
                    Text(engine.defaultOutput?.name ?? "—")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("System default")
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            // Routes.
            if engine.rules.isEmpty {
                Text("No routes yet — add one below.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            } else {
                ForEach(engine.rules) { rule in
                    routeRow(rule)
                }
            }
        }
    }

    @ViewBuilder
    private func routeRow(_ rule: RoutingRule) -> some View {
        let status = engine.statuses[rule.id] ?? .inactive
        let active = engine.isActive(rule.id)
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "app.dashed").foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
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
                .labelsHidden().toggleStyle(.switch).controlSize(.small)

                Button { engine.remove(rule.id) } label: {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            // Live meter only while the route is actually running.
            if active {
                SegmentMeter(level: levels[rule.id] ?? 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 26)
            }
        }
        .padding(8)
        .background(active ? Color.green.opacity(0.06) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
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
            Text("ADD ROUTE").font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
            Picker("App", selection: $selectedBundle) {
                Text("Choose app…").tag("")
                ForEach(apps) { app in Text(app.name).tag(app.id) }
            }.labelsHidden()
            Picker("Output", selection: $selectedDeviceUID) {
                Text("Choose output…").tag("")
                ForEach(devices) { dev in Text(dev.name).tag(dev.uid) }
            }.labelsHidden()
            Button(action: addRule) { Label("Add route", systemImage: "plus") }
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
