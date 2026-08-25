import Foundation

enum PreferencesStore {
    private static let idKey = "activeGroupID"
    private static let nameKey = "activeGroupDisplayName"
    private static let ipKey = "activeGroupCoordinatorIP"

    static var activeGroupID: String? {
        get { UserDefaults.standard.string(forKey: idKey) }
        set { UserDefaults.standard.set(newValue, forKey: idKey) }
    }

    static var activeGroupDisplayName: String? {
        get { UserDefaults.standard.string(forKey: nameKey) }
        set { UserDefaults.standard.set(newValue, forKey: nameKey) }
    }

    static var activeGroupCoordinatorIP: String? {
        get { UserDefaults.standard.string(forKey: ipKey) }
        set { UserDefaults.standard.set(newValue, forKey: ipKey) }
    }

    /// Used when the saved group no longer exists in a freshly fetched topology - leaving
    /// the stale coordinator IP behind means media keys keep POSTing to a player that is
    /// no longer a coordinator, which fails silently.
    static func clearActiveGroup() {
        activeGroupID = nil
        activeGroupDisplayName = nil
        activeGroupCoordinatorIP = nil
    }

    static func setActiveGroup(_ group: SonosGroup) {
        activeGroupID = group.id
        activeGroupDisplayName = group.displayName
        activeGroupCoordinatorIP = group.coordinatorIP
    }
}
