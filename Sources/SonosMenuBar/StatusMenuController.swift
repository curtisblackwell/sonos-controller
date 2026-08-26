import AppKit

final class StatusMenuController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var groups: [SonosGroup] = []
    private var accessibilityGranted = false
    /// Accessibility reads as granted but the tap still won't start - almost always a grant
    /// made while this process was already running.
    private var needsRelaunch = false

    var onGrantAccessTapped: (() -> Void)?
    var onOpenLocalNetworkSettingsTapped: (() -> Void)?
    var onSelectGroup: ((SonosGroup) -> Void)?
    var onRescanTapped: (() -> Void)?
    var onManageGroupsTapped: (() -> Void)?

    override init() {
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "hifispeaker.and.homepod", accessibilityDescription: "Sonos Controller")
        statusItem.button?.image?.isTemplate = true
        rebuildMenu()
    }

    func update(groups: [SonosGroup]) {
        self.groups = groups
        rebuildMenu()
    }

    /// The editor window can change the media key target too; this re-marks the menu
    /// without waiting for the next topology fetch.
    func refreshActiveGroupMarks() {
        rebuildMenu()
    }

    func update(accessibilityGranted: Bool) {
        self.accessibilityGranted = accessibilityGranted
        if !accessibilityGranted { needsRelaunch = false }
        rebuildMenu()
    }

    func updateNeedsRelaunch(_ needsRelaunch: Bool) {
        guard self.needsRelaunch != needsRelaunch else { return }
        self.needsRelaunch = needsRelaunch
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        if !accessibilityGranted {
            let item = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(grantAccess), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        } else if needsRelaunch {
            // Nothing here can fix it - the grant only takes effect in a fresh process - so
            // this says so rather than offering a button that would do nothing.
            let item = NSMenuItem(title: "Media Keys Need a Relaunch", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }

        if groups.isEmpty {
            let placeholder = NSMenuItem(title: "No Speakers Found", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            menu.addItem(placeholder)
            // A denied Local Network prompt is the most common cause and is otherwise
            // invisible - the app just never sees a speaker again.
            let localNetwork = NSMenuItem(title: "Check Local Network Access…", action: #selector(openLocalNetworkSettings), keyEquivalent: "")
            localNetwork.target = self
            menu.addItem(localNetwork)
        } else {
            let header = NSMenuItem(title: "Media Keys Control", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for group in groups {
                let item = NSMenuItem(title: group.displayName, action: #selector(selectGroup(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = group
                item.state = group.id == PreferencesStore.activeGroupID ? .on : .off
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let manage = NSMenuItem(title: "Manage Groups…", action: #selector(manageGroups), keyEquivalent: "g")
        manage.target = self
        menu.addItem(manage)

        let rescan = NSMenuItem(title: "Rescan for Speakers", action: #selector(rescan), keyEquivalent: "")
        rescan.target = self
        menu.addItem(rescan)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func grantAccess() {
        onGrantAccessTapped?()
    }

    @objc private func selectGroup(_ sender: NSMenuItem) {
        guard let group = sender.representedObject as? SonosGroup else { return }
        onSelectGroup?(group)
        rebuildMenu()
    }

    @objc private func openLocalNetworkSettings() {
        onOpenLocalNetworkSettingsTapped?()
    }

    @objc private func manageGroups() {
        onManageGroupsTapped?()
    }

    @objc private func rescan() {
        onRescanTapped?()
    }
}
