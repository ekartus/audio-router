import Foundation
import Combine
import CoreAudio

/// Owns the list of rules, persists them, and keeps a `ProcessAudioRouter`
/// running for each enabled rule whose app + device are currently available.
/// A periodic reconcile loop starts routes when their app/device appear and
/// tears them down when they disappear or the rule is turned off.
@MainActor
public final class RouteEngine: ObservableObject {
    @Published public private(set) var rules: [RoutingRule]
    @Published public private(set) var statuses: [UUID: RouteStatus] = [:]
    @Published public private(set) var defaultOutput: AudioDeviceInfo?

    private var routers: [UUID: ProcessAudioRouter] = [:]
    private var timer: Timer?

    /// Live output level (0…1) for an active route; 0 if inactive. Consuming —
    /// call at your display rate (returns the peak since the previous call).
    public func level(for id: UUID) -> Float {
        routers[id]?.readLevel() ?? 0
    }

    /// Whether a rule currently has a live router.
    public func isActive(_ id: UUID) -> Bool { routers[id] != nil }

    public init() {
        rules = RulesStore.load()
        defaultOutput = defaultOutputDevice()
        for r in rules { statuses[r.id] = r.enabled ? .waiting("starting…") : .inactive }
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
        reconcile()
    }

    // MARK: Rule editing

    public func add(_ rule: RoutingRule) {
        rules.append(rule)
        statuses[rule.id] = rule.enabled ? .waiting("starting…") : .inactive
        persistAndReconcile()
    }

    public func remove(_ id: UUID) {
        stopRoute(id)
        rules.removeAll { $0.id == id }
        statuses[id] = nil
        persistAndReconcile()
    }

    public func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[i].enabled = enabled
        if !enabled {
            stopRoute(id)
            statuses[id] = .inactive
        } else {
            statuses[id] = .waiting("starting…")
        }
        persistAndReconcile()
    }

    private func persistAndReconcile() {
        RulesStore.save(rules)
        reconcile()
    }

    // MARK: Reconcile loop

    private func reconcile() {
        defaultOutput = defaultOutputDevice()
        let devices = listOutputDevices()
        let processes = listAudioProcesses()

        for rule in rules {
            if !rule.enabled {
                if routers[rule.id] != nil { stopRoute(rule.id) }
                statuses[rule.id] = .inactive
                continue
            }

            let proc = processes.first { ($0.bundleID ?? "").caseInsensitiveCompare(rule.appBundleID) == .orderedSame }
            let device = devices.first { $0.uid == rule.deviceUID }

            if let existing = routers[rule.id] {
                // Running: verify its app + device still exist; otherwise recycle.
                if proc == nil || device == nil {
                    existing.stop()
                    routers[rule.id] = nil
                    statuses[rule.id] = .waiting(proc == nil ? "\(rule.appName) not running" : "\(rule.deviceName) unplugged")
                }
                continue
            }

            // Not running yet: start if both ends are available.
            guard let proc else { statuses[rule.id] = .waiting("\(rule.appName) not running"); continue }
            guard let device else { statuses[rule.id] = .waiting("\(rule.deviceName) unplugged"); continue }

            let router = ProcessAudioRouter()
            do {
                try router.start(processObjectID: proc.objectID, deviceID: device.id, deviceName: device.name)
                routers[rule.id] = router
                statuses[rule.id] = .active
            } catch {
                statuses[rule.id] = .error("\(error)")
            }
        }
    }

    private func stopRoute(_ id: UUID) {
        routers[id]?.stop()
        routers[id] = nil
    }

    public func stopAll() {
        for (_, r) in routers { r.stop() }
        routers.removeAll()
    }
}
