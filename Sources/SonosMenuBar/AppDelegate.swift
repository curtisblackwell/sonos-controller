import AppKit
import os.log

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "com.curtis.sonos-controller", category: "appdelegate")

    private let statusMenu = StatusMenuController()
    private let mediaKeyTap = MediaKeyTap()
    private let discovery = SonosDiscovery()
    private let topology = TopologyModel()
    private let topologySubscriber = TopologySubscriber()
    private var permissionPollTimer: Timer?
    /// Every player the last scan found, so a refresh has somewhere to ask without running
    /// another one.
    private var knownDeviceIPs: [String] = []
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

        // The editor's Refresh button and its post-grouping settle both re-read the topology
        // from a known player rather than rescanning for one.
        topology.refreshHandler = { [weak self] in
            self?.refreshTopology()
        }

        // Regrouping from the Sonos app arrives as a pushed event carrying the whole
        // topology, so there is nothing to fetch when one lands.
        topologySubscriber.onTopology = { [weak self] groups in
            self?.apply(groups: groups)
        }
        topologySubscriber.start()

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

        NSApp.mainMenu = MainMenu.build(appName: "SonosController")

        PermissionsManager.requestAccessibility()
        refreshPermissionState()
        startPermissionPolling()

        runDiscovery()

        // A .regular app that launches with nothing on screen reads as broken, and the
        // window is the main surface now.
        groupingWindow.present()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Leaves the speaker without a subscription it would otherwise keep trying to
        // deliver to until the lease runs out.
        topologySubscriber.stop()
    }

    /// The media key tap is the point of the app and it lives in the process, not in a
    /// window - closing the last window has to leave us running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon with no window open should bring the editor back rather than
    /// doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { groupingWindow.present() }
        return true
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

    /// The full SSDP scan: three seconds of multicast plus a description fetch per responder.
    /// Only worth paying when we have no idea where the speakers are - `refreshTopology` is
    /// the everyday path.
    private func runDiscovery() {
        discovery.discover { [weak self] devices in
            guard let self else { return }
            let ips = devices.map(\.ipAddress)
            // Keep the previous list when a scan finds nothing: a missed multicast round is
            // commoner than a household disappearing, and throwing the addresses away costs
            // the next Refresh a full scan to learn them again.
            if !ips.isEmpty { self.knownDeviceIPs = ips }
            // Also the subscriber's failover list: the speaker it is subscribed to may have
            // dropped off the network since the last scan.
            self.topologySubscriber.update(candidateIPs: ips)
            self.resolveGroups(candidateIPs: ips) { [weak self] in
                // Nothing answered. Distinct from `apply(groups: [])`: an empty fetch is not
                // evidence the saved group is gone, so the selection stays put.
                self?.statusMenu.update(groups: [])
                self?.topology.update(groups: [])
            }
        }
    }

    /// Re-reads the topology from a player we already know about - one SOAP round trip, no
    /// scan. This is what the editor's Refresh button and the settle after a grouping
    /// command use; making them rediscover the household added three seconds to every drag.
    private func refreshTopology() {
        let candidates = topologyCandidateIPs()
        guard !candidates.isEmpty else {
            runDiscovery()
            return
        }
        resolveGroups(candidateIPs: candidates) { [weak self] in
            // Every address we had is stale, so there is nothing left to ask - fall back to
            // finding the speakers again.
            Self.log.notice("No known player answered, falling back to a full scan")
            self?.runDiscovery()
        }
    }

    /// Coordinators first: they are the players we most recently saw answering, and the ones
    /// still holding a group together.
    private func topologyCandidateIPs() -> [String] {
        var seen = Set<String>()
        return (topology.groups.map(\.coordinatorIP) + knownDeviceIPs).filter { seen.insert($0).inserted }
    }

    /// GetZoneGroupState can be asked of any single reachable ZonePlayer and returns the
    /// whole household's topology, so we just need one candidate to answer - try each in
    /// turn in case the first one is unreachable. `whenNoneAnswer` runs if none of them does.
    private func resolveGroups(candidateIPs: [String], index: Int = 0, whenNoneAnswer: @escaping () -> Void) {
        guard index < candidateIPs.count else {
            whenNoneAnswer()
            return
        }
        SonosTopology.fetchGroups(from: candidateIPs[index]) { [weak self] groups in
            guard let self else { return }
            guard !groups.isEmpty else {
                self.resolveGroups(candidateIPs: candidateIPs, index: index + 1, whenNoneAnswer: whenNoneAnswer)
                return
            }
            self.apply(groups: groups)
        }
    }

    /// The single place a new topology - fetched or pushed - reaches the UI.
    private func apply(groups: [SonosGroup]) {
        // Reconcile the saved selection before rebuilding the menu, so its checkmark
        // reflects what we just resolved. A group that has disappeared from the topology
        // (regrouped elsewhere) is cleared rather than left pointing at an IP that is no
        // longer a coordinator.
        if let activeID = PreferencesStore.activeGroupID {
            if let match = groups.first(where: { $0.id == activeID }) {
                PreferencesStore.setActiveGroup(match)
            } else {
                Self.log.notice("Saved group \(activeID, privacy: .public) is gone from the topology, clearing it")
                PreferencesStore.clearActiveGroup()
            }
        }
        statusMenu.update(groups: groups)
        topology.update(groups: groups)
    }
}
