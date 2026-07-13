import Foundation

/// One routing rule: send `appBundleID`'s audio to the output device `deviceUID`.
public struct RoutingRule: Identifiable, Codable, Hashable {
    public var id: UUID
    public var appName: String
    public var appBundleID: String
    public var deviceName: String
    public var deviceUID: String
    public var enabled: Bool

    public init(id: UUID = UUID(), appName: String, appBundleID: String,
                deviceName: String, deviceUID: String, enabled: Bool = true) {
        self.id = id
        self.appName = appName
        self.appBundleID = appBundleID
        self.deviceName = deviceName
        self.deviceUID = deviceUID
        self.enabled = enabled
    }
}

/// Live status of a rule's routing.
public enum RouteStatus: Equatable {
    case inactive
    case waiting(String)   // enabled but not yet routable (app not running, device unplugged…)
    case active
    case error(String)

    public var label: String {
        switch self {
        case .inactive: return "Off"
        case .waiting(let r): return "Waiting — \(r)"
        case .active: return "Routing"
        case .error(let e): return "Error — \(e)"
        }
    }
}

/// Persists rules to UserDefaults as JSON.
public enum RulesStore {
    private static let key = "MixerApp.rules.v1"

    public static func load() -> [RoutingRule] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let rules = try? JSONDecoder().decode([RoutingRule].self, from: data)
        else { return [] }
        return rules
    }

    public static func save(_ rules: [RoutingRule]) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
