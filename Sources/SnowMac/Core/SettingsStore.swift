import Foundation
import CoreGraphics

/// UserDefaults-backed settings for SnowMac. Changes propagate via NotificationCenter.
final class SettingsStore {
    static let shared = SettingsStore()

    static let didChange = Notification.Name("SettingsStore.didChange")

    private enum Keys {
        static let intensity = "snowmac.intensity"
        static let snowOnWindows = "snowmac.snowOnWindows"
        static let snowOnDock = "snowmac.snowOnDock"
        static let disabledDisplays = "snowmac.disabledDisplays"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var intensity: SnowIntensity {
        get {
            if let raw = defaults.string(forKey: Keys.intensity),
               let value = SnowIntensity(rawValue: raw) {
                return value
            }
            return .normal
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.intensity)
            notifyChange()
        }
    }

    var snowOnWindows: Bool {
        get {
            if defaults.object(forKey: Keys.snowOnWindows) == nil { return true }
            return defaults.bool(forKey: Keys.snowOnWindows)
        }
        set {
            defaults.set(newValue, forKey: Keys.snowOnWindows)
            notifyChange()
        }
    }

    var snowOnDock: Bool {
        get {
            if defaults.object(forKey: Keys.snowOnDock) == nil { return true }
            return defaults.bool(forKey: Keys.snowOnDock)
        }
        set {
            defaults.set(newValue, forKey: Keys.snowOnDock)
            notifyChange()
        }
    }

    /// IDs of displays the user has disabled snow for. Default empty = all
    /// displays enabled (current/original behavior).
    private var disabledDisplayIDs: Set<CGDirectDisplayID> {
        get {
            guard let raw = defaults.array(forKey: Keys.disabledDisplays) as? [Int] else { return [] }
            return Set(raw.map { CGDirectDisplayID($0) })
        }
        set {
            defaults.set(newValue.map { Int($0) }, forKey: Keys.disabledDisplays)
            notifyChange()
        }
    }

    func isDisplayEnabled(_ id: CGDirectDisplayID) -> Bool {
        !disabledDisplayIDs.contains(id)
    }

    func setDisplay(_ id: CGDirectDisplayID, enabled: Bool) {
        var disabled = disabledDisplayIDs
        if enabled {
            disabled.remove(id)
        } else {
            disabled.insert(id)
        }
        disabledDisplayIDs = disabled
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: SettingsStore.didChange, object: self)
    }
}
