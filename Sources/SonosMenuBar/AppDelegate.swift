import AppKit
import os.log

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "com.curtis.sonos-controller", category: "appdelegate")

    private let statusMenu = StatusMenuController()
    private let mediaKeyTap = MediaKeyTap()
    private let discovery = SonosDiscovery()
    private let topology = TopologyModel()
    private var permissionPollTimer: Timer?
    private lazy var groupingWindow = GroupingWindowController(model: topology)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusMenu.onGrantAccessTapped = {
            PermissionsManager.requestAccessibility()
            PermissionsManager.openAccessibilitySettings()
        }
        statusMenu.onOpenLocalNetworkSettingsTapped = {
            PermissionsManager.openLocalNetworkSettings()
        }
        // Both surfaces pick the media key target, so each has to tell the other.
        statusMenu.onSelectGroup = { [weak self] group in
            self?.topology.setActiveGroup(group)
        }
        topology.onActiveGroupChanged = { [weak self] in
            self?.statusMenu.refreshActiveGroupMarks()
        }
        statusMenu.onRescanTapped = { [weak self] in
            self?.runDiscovery()
        }
        statusMenu.onManageGroupsTapped = { [weak self] in
            self?.groupingWindow.present()
        }

        // The editor's Refresh button and its post-grouping settle both re-run discovery,
        // which is also what picks up rooms that were regrouped from the Sonos app.
        topology.refreshHandler = { [weak self] in
            self?.runDiscovery()
        }

        mediaKeyTap.onPlayPause = {
            Self.log.notice("onPlayPause fired, target IP=\(PreferencesStore.activeGroupCoordinatorIP ?? "nil", privacy: .public)")
            guard let ip = PreferencesStore.activeGroupCoordinatorIP else { return }
            SonosControl.togglePlayPause(ip: ip)
        }
        mediaKeyTap.onNext = {
            Self.log.notice("onNext fired, target IP=\(PreferencesStore.activeGroupCoordinatorIP ?? "nil", privacy: .public)")
            guard let ip = PreferencesStore.activeGroupCoordinatorIP else { return }
            SonosControl.send(action: .next, to: ip)
        }
        mediaKeyTap.onPrevious = {
            Self.log.notice("onPrevious fired, target IP=\(PreferencesStore.activeGroupCoordinatorIP ?? "nil", privacy: .public)")
            guard let ip = PreferencesStore.activeGroupCoordinatorIP else { return }
            SonosControl.send(action: .previous, to: ip)
        }

        PermissionsManager.requestAccessibility()
        refreshPermissionState()
        startPermissionPolling()

        runDiscovery()
    }

    private func refreshPermissionState() {
        let granted = PermissionsManager.accessibilityGranted()
        Self.log.notice("accessibilityGranted=\(granted, privacy: .public)")
        statusMenu.update(accessibilityGranted: granted)
        if granted {
            let installed = mediaKeyTap.install()
            Self.log.notice("mediaKeyTap.install() returned \(installed, privacy: .public)")
        }
    }

    private func startPermissionPolling() {
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshPermissionState()
        }
    }

    private func runDiscovery() {
        discovery.discover { [weak self] devices in
            self?.resolveGroups(candidateIPs: devices.map(\.ipAddress))
        }
    }

    /// GetZoneGroupState can be asked of any single reachable ZonePlayer and returns the
    /// whole household's topology, so we just need one candidate to answer - try each in
    /// turn in case the first one is unreachable.
    private func resolveGroups(candidateIPs: [String], index: Int = 0) {
        guard index < candidateIPs.count else {
            statusMenu.update(groups: [])
            topology.update(groups: [])
            return
        }
        SonosTopology.fetchGroups(from: candidateIPs[index]) { [weak self] groups in
            guard let self else { return }
            guard !groups.isEmpty else {
                self.resolveGroups(candidateIPs: candidateIPs, index: index + 1)
                return
            }
            // Reconcile the saved selection before rebuilding the menu, so its checkmark
            // reflects what we just resolved. A group that has disappeared from the
            // topology (regrouped elsewhere) is cleared rather than left pointing at an
            // IP that is no longer a coordinator.
            if let activeID = PreferencesStore.activeGroupID {
                if let match = groups.first(where: { $0.id == activeID }) {
                    PreferencesStore.setActiveGroup(match)
                } else {
                    Self.log.notice("Saved group \(activeID, privacy: .public) is gone from the topology, clearing it")
                    PreferencesStore.clearActiveGroup()
                }
            }
            self.statusMenu.update(groups: groups)
            self.topology.update(groups: groups)
        }
    }
}
