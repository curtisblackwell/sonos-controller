import Combine
import Foundation
import os.log

/// The household's volume state, and the writes that change it.
///
/// Reads are polled rather than pushed. The topology gets away with a single GENA
/// subscription because any one player reports the whole household; volume has no such
/// endpoint - it would take a RenderingControl subscription per player plus a
/// GroupRenderingControl one per coordinator, each with its own lease to renew, fail over,
/// and rebuild after a wake. A GetVolume is a few hundred bytes on the LAN, so polling is
/// the cheaper trade here - and it only runs while the window showing the sliders is
/// actually on screen.
///
/// Main thread only. `VolumeControl` delivers every completion there, so nothing below
/// needs synchronisation.
final class VolumeModel: ObservableObject {
    private static let log = Logger(subsystem: "com.curtisblackwell.sonos-controller", category: "volume-model")

    /// Fast enough that a change made in the Sonos app shows up while you are still looking
    /// at the window, slow enough that a household of a dozen rooms isn't a traffic source.
    private static let pollInterval: TimeInterval = 2.5

    /// After a write pipeline drains, one extra read - setting a room's volume changes its
    /// group's, and waiting a whole poll for the group slider to catch up looks like a bug.
    private static let refreshDebounce: TimeInterval = 0.35

    /// Volume 0-100 per group id. Only groups with more than one room are tracked: a
    /// standalone group's volume is its single room's, and asking twice for the same number
    /// doubles the polling for the commonest case.
    @Published private(set) var groupVolume: [String: Int] = [:]
    @Published private(set) var groupMuted: [String: Bool] = [:]
    /// Volume 0-100 per room uuid.
    @Published private(set) var roomVolume: [String: Int] = [:]
    @Published private(set) var roomMuted: [String: Bool] = [:]
    /// Set while a match-to-quietest is reading the speakers it is about to write to.
    @Published private(set) var isSyncing = false
    @Published var errorMessage: String?

    private var groups: [SonosGroup] = []
    private var pollTimer: Timer?
    private var refreshTimer: Timer?

    /// Which value a write targets. Volume and mute are separate targets on purpose: they
    /// are independent writes, and coalescing one behind the other would drop it.
    private enum Target: Hashable {
        case groupVolume(String)
        case groupMute(String)
        case roomVolume(String)
        case roomMute(String)
    }

    /// One request in flight per target, latest value wins. A slider drag emits a write per
    /// frame; sending them all would queue dozens of round trips behind a knob the user has
    /// already let go of.
    private var inFlight: Set<Target> = []
    private var queued: [Target: Int] = [:]
    /// Bumped on every write. A poll issued before a write carries the old generation, so
    /// its answer - which may arrive after the write landed - is discarded instead of
    /// snapping the slider back to where it was.
    private var writeGeneration: [Target: Int] = [:]

    var isWatching: Bool { pollTimer != nil }

    // MARK: - Topology

    func update(groups: [SonosGroup]) {
        self.groups = groups

        // Drop readings for anything that has gone. Regrouping retires group ids constantly,
        // and a dictionary that only ever grows would keep stale numbers around to be shown
        // the moment an id came back.
        let liveGroupIDs = Set(groups.filter { !$0.isStandalone }.map(\.id))
        let liveRoomIDs = Set(groups.flatMap(\.members).map(\.uuid))
        groupVolume = groupVolume.filter { liveGroupIDs.contains($0.key) }
        groupMuted = groupMuted.filter { liveGroupIDs.contains($0.key) }
        roomVolume = roomVolume.filter { liveRoomIDs.contains($0.key) }
        roomMuted = roomMuted.filter { liveRoomIDs.contains($0.key) }

        if isWatching { refresh() }
    }

    // MARK: - Polling

    /// Called when the window becomes visible. Idempotent.
    func startPolling() {
        guard pollTimer == nil else { return }
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// A read of everything on screen. Two requests per multi-room group and two per room -
    /// mute has no combined read with volume, so it costs its own.
    func refresh() {
        for group in groups where !group.isStandalone {
            read(.groupVolume(group.id))
            read(.groupMute(group.id))
        }
        for room in groups.flatMap(\.members) {
            read(.roomVolume(room.uuid))
            read(.roomMute(room.uuid))
        }
    }

    /// A coalesced refresh, ignored when nobody is looking. Safe to call from a held-down
    /// volume key: the timer restarts rather than the reads stacking up.
    func refreshSoon() {
        guard isWatching else { return }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshDebounce, repeats: false) { [weak self] _ in
            self?.refreshTimer = nil
            self?.refresh()
        }
    }

    // MARK: - Reading the UI's state

    func volume(forGroup group: SonosGroup) -> Int? {
        group.isStandalone ? group.members.first.flatMap { roomVolume[$0.uuid] } : groupVolume[group.id]
    }

    func isMuted(group: SonosGroup) -> Bool {
        group.isStandalone ? (group.members.first.flatMap { roomMuted[$0.uuid] } ?? false) : (groupMuted[group.id] ?? false)
    }

    func volume(forRoom room: SonosRoom) -> Int? { roomVolume[room.uuid] }

    func isMuted(room: SonosRoom) -> Bool { roomMuted[room.uuid] ?? false }

    // MARK: - Writing

    func setVolume(_ volume: Int, forGroup group: SonosGroup) {
        let value = VolumeControl.clamped(volume)
        // A standalone group has no members to balance, and GroupRenderingControl on a group
        // of one is a longer way round to the same write.
        if group.isStandalone, let room = group.members.first {
            setVolume(value, forRoom: room)
            return
        }
        groupVolume[group.id] = value
        write(.groupVolume(group.id), value: value)
    }

    func toggleMute(group: SonosGroup) {
        if group.isStandalone, let room = group.members.first {
            toggleMute(room: room)
            return
        }
        let muted = !isMuted(group: group)
        groupMuted[group.id] = muted
        write(.groupMute(group.id), value: muted ? 1 : 0)
    }

    func setVolume(_ volume: Int, forRoom room: SonosRoom) {
        let value = VolumeControl.clamped(volume)
        roomVolume[room.uuid] = value
        write(.roomVolume(room.uuid), value: value)
    }

    func toggleMute(room: SonosRoom) {
        let muted = !isMuted(room: room)
        roomMuted[room.uuid] = muted
        write(.roomMute(room.uuid), value: muted ? 1 : 0)
    }

    // MARK: - Match to quietest

    func syncToQuietest(in group: SonosGroup) {
        syncToQuietest(rooms: group.members, describedAs: group.displayName)
    }

    func syncEverythingToQuietest() {
        syncToQuietest(rooms: groups.flatMap(\.members), describedAs: "every room")
    }

    /// Reads every room, then writes the quietest reading to the rest.
    ///
    /// Lowest rather than average or highest, because it is the only choice that can't make
    /// anything louder than the user already had it - which is the whole point when the
    /// quiet room is the one somebody is asleep in.
    ///
    /// Reads first because there is no other way to know which room is the quiet one, and a
    /// room that doesn't answer is left out of the decision entirely: treating an
    /// unreachable speaker as 0 would drag the whole household to silence.
    private func syncToQuietest(rooms: [SonosRoom], describedAs description: String) {
        guard !isSyncing, rooms.count > 1 else { return }
        isSyncing = true

        // Every completion below lands on the main thread, and so does `notify`, so these
        // are only ever touched from one thread despite the concurrent requests.
        var readings: [String: Int] = [:]
        var unreachable: [String] = []
        let waiting = DispatchGroup()

        for room in rooms {
            waiting.enter()
            VolumeControl.roomVolume(ip: room.ipAddress) { value in
                if let value {
                    readings[room.uuid] = value
                } else {
                    unreachable.append(room.name)
                }
                waiting.leave()
            }
        }

        waiting.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.isSyncing = false

            guard let plan = Self.quietestSync(volumes: readings) else {
                Self.log.notice("Nothing to match in \(description, privacy: .public)")
                if !unreachable.isEmpty {
                    self.errorMessage = Self.unreachableMessage(unreachable, matched: nil)
                }
                return
            }

            Self.log.notice("Matching \(plan.rooms.count, privacy: .public) rooms in \(description, privacy: .public) to \(plan.volume, privacy: .public)")
            for uuid in plan.rooms {
                guard let room = rooms.first(where: { $0.uuid == uuid }) else { continue }
                self.setVolume(plan.volume, forRoom: room)
            }
            if !unreachable.isEmpty {
                self.errorMessage = Self.unreachableMessage(unreachable, matched: plan.volume)
            }
        }
    }

    /// The volume everything should be matched to, and which rooms actually need a write.
    ///
    /// Nil means there is nothing to do: fewer than two readings to compare, or they already
    /// agree. Callers must check it before showing progress - nothing would ever clear it.
    static func quietestSync(volumes: [String: Int]) -> (volume: Int, rooms: [String])? {
        guard volumes.count > 1, let lowest = volumes.values.min() else { return nil }
        let rooms = volumes.filter { $0.value != lowest }.keys.sorted()
        guard !rooms.isEmpty else { return nil }
        return (lowest, rooms)
    }

    private static func unreachableMessage(_ names: [String], matched volume: Int?) -> String {
        let list = names.sorted().joined(separator: ", ")
        guard let volume else {
            return "Couldn't reach \(list), so there was nothing to match."
        }
        return "Matched the rest to \(volume), but couldn't reach \(list)."
    }

    // MARK: - Write pipeline

    private func write(_ target: Target, value: Int) {
        writeGeneration[target, default: 0] += 1
        queued[target] = value
        flush(target)
    }

    private func flush(_ target: Target) {
        guard !inFlight.contains(target), let value = queued.removeValue(forKey: target) else { return }
        guard let send = sender(for: target) else { return }
        inFlight.insert(target)
        send(value) { [weak self] in
            guard let self else { return }
            self.inFlight.remove(target)
            if self.queued[target] != nil {
                self.flush(target)
            } else {
                // A room write moves its group's volume too, so the drain is the moment the
                // other sliders are wrong.
                self.refreshSoon()
            }
        }
    }

    private func sender(for target: Target) -> ((Int, @escaping () -> Void) -> Void)? {
        switch target {
        case let .groupVolume(id):
            guard let ip = coordinatorIP(groupID: id) else { return nil }
            return { value, done in VolumeControl.setGroupVolume(value, coordinatorIP: ip) { _ in done() } }
        case let .groupMute(id):
            guard let ip = coordinatorIP(groupID: id) else { return nil }
            return { value, done in VolumeControl.setGroupMute(value != 0, coordinatorIP: ip) { _ in done() } }
        case let .roomVolume(uuid):
            guard let ip = roomIP(uuid: uuid) else { return nil }
            return { value, done in VolumeControl.setRoomVolume(value, ip: ip) { _ in done() } }
        case let .roomMute(uuid):
            guard let ip = roomIP(uuid: uuid) else { return nil }
            return { value, done in VolumeControl.setRoomMute(value != 0, ip: ip) { _ in done() } }
        }
    }

    // MARK: - Read pipeline

    private func read(_ target: Target) {
        guard let fetch = reader(for: target) else { return }
        let generation = writeGeneration[target] ?? 0
        fetch { [weak self] value in
            guard let self, let value else { return }
            // Anything written since this read went out - including one still in flight -
            // is newer than the answer, whatever order they came back in.
            guard self.writeGeneration[target] ?? 0 == generation, !self.inFlight.contains(target) else { return }
            self.store(value, for: target)
        }
    }

    private func reader(for target: Target) -> ((@escaping (Int?) -> Void) -> Void)? {
        switch target {
        case let .groupVolume(id):
            guard let ip = coordinatorIP(groupID: id) else { return nil }
            return { done in VolumeControl.groupVolume(coordinatorIP: ip, completion: done) }
        case let .groupMute(id):
            guard let ip = coordinatorIP(groupID: id) else { return nil }
            return { done in VolumeControl.groupMute(coordinatorIP: ip) { done($0.map { $0 ? 1 : 0 }) } }
        case let .roomVolume(uuid):
            guard let ip = roomIP(uuid: uuid) else { return nil }
            return { done in VolumeControl.roomVolume(ip: ip, completion: done) }
        case let .roomMute(uuid):
            guard let ip = roomIP(uuid: uuid) else { return nil }
            return { done in VolumeControl.roomMute(ip: ip) { done($0.map { $0 ? 1 : 0 }) } }
        }
    }

    private func store(_ value: Int, for target: Target) {
        switch target {
        case let .groupVolume(id): groupVolume[id] = VolumeControl.clamped(value)
        case let .groupMute(id): groupMuted[id] = value != 0
        case let .roomVolume(uuid): roomVolume[uuid] = VolumeControl.clamped(value)
        case let .roomMute(uuid): roomMuted[uuid] = value != 0
        }
    }

    // MARK: - Addresses

    private func coordinatorIP(groupID: String) -> String? {
        groups.first { $0.id == groupID }?.coordinatorIP
    }

    private func roomIP(uuid: String) -> String? {
        groups.flatMap(\.members).first { $0.uuid == uuid }?.ipAddress
    }
}
