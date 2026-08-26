import Combine
import Foundation
import os.log

/// The household's volume state, and the writes that change it.
///
/// Group volume is scaled here rather than by `GroupRenderingControl`, which cannot be
/// trusted with it. That service keeps its *own* remembered balance for a group and
/// re-imposes it on every write, and nothing this app does to a member with `SetVolume` -
/// a room slider, a match-to-quietest - updates that snapshot. Measured on a real household:
/// four speakers set to 7 apiece, one `SetRelativeGroupVolume(+6)`, and they land on
/// 3/18/22/9 - the old spread, with the quietest speaker moving *down* on a volume-up.
///
/// So the group's volume is the mean of its members, and moving it scales the members by the
/// ratio the user asked for, which leaves a group that was already level exactly level. Mute
/// is the exception and stays a group call: it carries no balance to get wrong, and it was
/// measured leaving member volumes untouched.
///
/// Reads are polled rather than pushed. The topology gets away with a single GENA
/// subscription because any one player reports the whole household; volume has no such
/// endpoint - it would take a RenderingControl subscription per player, each with its own
/// lease to renew, fail over, and rebuild after a wake. A GetVolume is a few hundred bytes
/// on the LAN, so polling is the cheaper trade here - and it only runs while the window
/// showing the sliders is actually on screen.
///
/// Main thread only. `VolumeControl` delivers every completion there, so nothing below
/// needs synchronisation.
final class VolumeModel: ObservableObject {
    private static let log = Logger(subsystem: "com.curtisblackwell.sonos-controller", category: "volume-model")

    /// Fast enough that a change made in the Sonos app shows up while you are still looking
    /// at the window, slow enough that a household of a dozen rooms isn't a traffic source.
    private static let pollInterval: TimeInterval = 2.5

    /// After a write pipeline drains, one extra read - a room write moves its group's
    /// average, and waiting a whole poll for the other sliders to agree looks like a bug.
    private static let refreshDebounce: TimeInterval = 0.35

    /// How long a volume key's baseline outlives the last press. Long enough that a held key
    /// ramps against one snapshot, short enough that the next press after a pause measures
    /// against whatever the speakers are actually doing by then.
    private static let keyBaselineLifetime: TimeInterval = 2

    /// Volume 0-100 per room uuid. The only volume state there is; group sliders are a view
    /// of it.
    @Published private(set) var roomVolume: [String: Int] = [:]
    @Published private(set) var roomMuted: [String: Bool] = [:]
    /// Mute per group id, straight from the coordinator. Only groups with more than one room
    /// are tracked - a standalone group's mute is its single room's.
    @Published private(set) var groupMuted: [String: Bool] = [:]
    /// Set while a match-to-quietest is reading the speakers it is about to write to.
    @Published private(set) var isSyncing = false
    @Published var errorMessage: String?

    private var groups: [SonosGroup] = []
    private var pollTimer: Timer?
    private var refreshTimer: Timer?

    /// What a group's members were at when the user took hold of its slider.
    ///
    /// Every position during the drag is applied against this rather than against wherever
    /// the last one landed, so a speaker that hits 0 or 100 partway through doesn't drag the
    /// rest of the group out of balance - pull the slider back and the group comes back to
    /// exactly what it was.
    private struct GroupDrag {
        let groupVolume: Int
        let rooms: [String: Int]
        /// Where the user has actually put the slider. Clamping means the members' average
        /// can stop short of it, and a slider that creeps back under the pointer is worse
        /// than one that sits still while the speakers run out of room.
        var position: Int
    }
    private var groupDrags: [String: GroupDrag] = [:]
    /// Ends the implicit drag a volume key opens. Sliders end theirs explicitly.
    private var groupDragExpiry: [String: Timer] = [:]

    /// Which value a write targets. Volume and mute are separate targets on purpose: they
    /// are independent writes, and coalescing one behind the other would drop it.
    private enum Target: Hashable {
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
        groupMuted = groupMuted.filter { liveGroupIDs.contains($0.key) }
        roomVolume = roomVolume.filter { liveRoomIDs.contains($0.key) }
        roomMuted = roomMuted.filter { liveRoomIDs.contains($0.key) }
        // A group that has been regrouped underneath a held slider has no members left to
        // apply the drag to.
        for id in groupDrags.keys where !liveGroupIDs.contains(id) { endGroupDrag(id) }

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

    /// A read of everything on screen: two requests per room, plus one per multi-room group
    /// for the mute the coordinator owns. Mute has no combined read with volume, so it costs
    /// its own request.
    func refresh() {
        for group in groups where !group.isStandalone {
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
        if let drag = groupDrags[group.id] { return drag.position }
        return Self.averageVolume(of: group.members, in: roomVolume)
    }

    func isMuted(group: SonosGroup) -> Bool {
        group.isStandalone ? (group.members.first.flatMap { roomMuted[$0.uuid] } ?? false) : (groupMuted[group.id] ?? false)
    }

    func volume(forRoom room: SonosRoom) -> Int? { roomVolume[room.uuid] }

    func isMuted(room: SonosRoom) -> Bool { roomMuted[room.uuid] ?? false }

    /// What a group slider sits at: the mean of its members.
    ///
    /// Nil unless *every* member has been read. An average over only the rooms that answered
    /// would be a number the slider could sit at but not move from correctly - the first
    /// nudge would apply a delta measured against a baseline that doesn't describe the group.
    static func averageVolume(of members: [SonosRoom], in readings: [String: Int]) -> Int? {
        guard !members.isEmpty else { return nil }
        var total = 0
        for member in members {
            guard let volume = readings[member.uuid] else { return nil }
            total += volume
        }
        return Int((Double(total) / Double(members.count)).rounded())
    }

    // MARK: - Writing

    /// Takes hold of a group slider, so the drag is measured from one baseline rather than
    /// accumulating. Without it - a keyboard adjustment, VoiceOver - each change is measured
    /// against the current state instead, which is right, just lossy at the ends.
    func beginGroupDrag(_ group: SonosGroup) {
        guard !group.isStandalone, let baseline = snapshot(of: group) else { return }
        groupDrags[group.id] = baseline
    }

    func endGroupDrag(_ group: SonosGroup) {
        endGroupDrag(group.id)
    }

    private func endGroupDrag(_ groupID: String) {
        groupDrags[groupID] = nil
        groupDragExpiry.removeValue(forKey: groupID)?.invalidate()
    }

    /// A volume key press. Successive presses accumulate against one baseline - a held key
    /// ramping against re-read state would compound its own rounding - and the baseline is
    /// dropped once the presses stop.
    ///
    /// Unlike the slider this may have nothing to work from: the keys run whether or not the
    /// window is open, so the members are read first when there are no readings to hand.
    func nudgeVolume(forGroup group: SonosGroup, by delta: Int) {
        if group.isStandalone, let room = group.members.first {
            guard let current = roomVolume[room.uuid] else {
                readMembers(of: group) { [weak self] in self?.nudgeVolume(forGroup: group, by: delta) }
                return
            }
            setVolume(current + delta, forRoom: room)
            return
        }
        guard groupDrags[group.id] != nil || snapshot(of: group) != nil else {
            readMembers(of: group) { [weak self] in self?.nudgeVolume(forGroup: group, by: delta) }
            return
        }
        if groupDrags[group.id] == nil { beginGroupDrag(group) }
        guard let current = volume(forGroup: group) else { return }
        setVolume(current + delta, forGroup: group)

        groupDragExpiry.removeValue(forKey: group.id)?.invalidate()
        groupDragExpiry[group.id] = Timer.scheduledTimer(
            withTimeInterval: Self.keyBaselineLifetime,
            repeats: false
        ) { [weak self] _ in
            self?.endGroupDrag(group.id)
        }
    }

    /// One read of every member, outside the poll. The keys need it when the window is shut
    /// and there is no polled state to nudge.
    private func readMembers(of group: SonosGroup, then completion: @escaping () -> Void) {
        let waiting = DispatchGroup()
        for room in group.members {
            waiting.enter()
            VolumeControl.roomVolume(ip: room.ipAddress) { [weak self] value in
                if let value { self?.roomVolume[room.uuid] = value }
                waiting.leave()
            }
        }
        waiting.notify(queue: .main) {
            completion()
        }
    }

    /// Scales every member of the group toward the requested group volume.
    func setVolume(_ volume: Int, forGroup group: SonosGroup) {
        // A group of one has nothing to keep in step, and the room write is the same thing
        // by a shorter route.
        if group.isStandalone, let room = group.members.first {
            setVolume(volume, forRoom: room)
            return
        }
        let value = VolumeControl.clamped(volume)
        guard let baseline = groupDrags[group.id] ?? snapshot(of: group) else { return }
        if groupDrags[group.id] != nil { groupDrags[group.id]?.position = value }

        for (uuid, target) in Self.memberTargets(baseline: baseline.rooms, movingFrom: baseline.groupVolume, to: value) {
            // Skipping against where the speaker is *now*, not against the baseline: a drag
            // returned to where it started has to write the baseline back, and a member that
            // rounds to the same number as last frame doesn't need a request spent on it.
            guard roomVolume[uuid] != target,
                  let room = group.members.first(where: { $0.uuid == uuid }) else { continue }
            setVolume(target, forRoom: room)
        }
    }

    /// Where each member ends up when a group's volume moves from `groupVolume` to `target`.
    ///
    /// Each member keeps its share: a group at 22/34 asked to go from 28 to 42 lands on
    /// 33/51, and - the case `GroupRenderingControl` gets wrong - a group already level at 7
    /// asked for 13 lands on 13 apiece rather than fanning back out.
    ///
    /// Rounding means the members' new mean can miss `target` by a point. That is why a drag
    /// holds the slider where the user put it rather than following the mean back.
    ///
    /// Every member is returned, including ones whose target equals their baseline: partway
    /// through a drag the speakers are nowhere near the baseline, so "unchanged since the
    /// drag started" is not the same as "nothing to write". Deciding what to skip needs the
    /// speakers' current state, which is the caller's to check.
    static func memberTargets(baseline: [String: Int], movingFrom groupVolume: Int, to target: Int) -> [String: Int] {
        // Silence has no ratio to preserve - every member is 0, and 0 times anything is still
        // 0, so a group scaled to the bottom could never be brought back up. Move them
        // together instead, which is the one case where the balance is already gone anyway.
        guard groupVolume > 0 else {
            return baseline.mapValues { VolumeControl.clamped($0 + target) }
        }
        let ratio = Double(target) / Double(groupVolume)
        return baseline.mapValues { VolumeControl.clamped(Int((Double($0) * ratio).rounded())) }
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

    private func snapshot(of group: SonosGroup) -> GroupDrag? {
        guard let current = Self.averageVolume(of: group.members, in: roomVolume) else { return nil }
        var rooms: [String: Int] = [:]
        for member in group.members {
            guard let volume = roomVolume[member.uuid] else { return nil }
            rooms[member.uuid] = volume
        }
        return GroupDrag(groupVolume: current, rooms: rooms, position: current)
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
                // A room write moves its group's average too, so the drain is the moment the
                // other sliders are wrong.
                self.refreshSoon()
            }
        }
    }

    private func sender(for target: Target) -> ((Int, @escaping () -> Void) -> Void)? {
        switch target {
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
