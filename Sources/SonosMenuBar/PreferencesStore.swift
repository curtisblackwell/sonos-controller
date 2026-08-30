import Foundation

enum PreferencesStore {
    private static let idKey = "activeGroupID"
    private static let nameKey = "activeGroupDisplayName"
    private static let ipKey = "activeGroupCoordinatorIP"
    private static let sidebarKey = "selectedSidebarItem"

    /// The bundle identifier before it was corrected to `com.curtisblackwell.*`. Renaming it
    /// moved the app to a fresh `UserDefaults` domain, so anyone who ran a build from before
    /// the rename has their saved group sitting in the old one.
    private static let legacyDomain = "com.curtis.sonos-controller"
    private static let migrationKey = "didMigrateLegacyDefaults"

    /// Copies the saved group over from the pre-rename domain, once. Runs before anything
    /// reads a preference; a no-op for a fresh install, and never overwrites a value that
    /// already exists in the current domain.
    static func migrateLegacyDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey) else { return }
        defaults.set(true, forKey: migrationKey)

        guard let legacy = UserDefaults(suiteName: legacyDomain) else { return }
        for key in [idKey, nameKey, ipKey] {
            guard defaults.string(forKey: key) == nil,
                  let value = legacy.string(forKey: key) else { continue }
            defaults.set(value, forKey: key)
        }
    }

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

    /// The page the window was last showing. Falls back to Speakers for a fresh install, and
    /// for a stored value that no longer names a page.
    static var selectedSidebarItem: SidebarItem {
        get {
            UserDefaults.standard.string(forKey: sidebarKey)
                .flatMap(SidebarItem.init(rawValue:)) ?? .speakers
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: sidebarKey) }
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
