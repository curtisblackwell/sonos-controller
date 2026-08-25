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

    static func setActiveGroup(_ group: SonosGroup) {
        activeGroupID = group.id
        activeGroupDisplayName = group.displayName
        activeGroupCoordinatorIP = group.coordinatorIP
    }
}
