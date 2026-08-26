import Foundation
import os.log

/// One player's own volume and mute.
///
/// `Channel` is always `Master`. Sonos exposes LF/RF channels too, but they are a stereo
/// trim rather than a volume control, and nothing in this app offers them.
enum RenderingAction: SonosSOAPAction {
    case getVolume
    case setVolume(Int)
    case getMute
    case setMute(Bool)

    var service: SonosService { .renderingControl }

    var name: String {
        switch self {
        case .getVolume: return "GetVolume"
        case .setVolume: return "SetVolume"
        case .getMute: return "GetMute"
        case .setMute: return "SetMute"
        }
    }

    var arguments: [(name: String, value: String)] {
        switch self {
        case .getVolume, .getMute:
            return [("Channel", "Master")]
        case let .setVolume(volume):
            return [("Channel", "Master"), ("DesiredVolume", String(VolumeControl.clamped(volume)))]
        case let .setMute(muted):
            return [("Channel", "Master"), ("DesiredMute", muted ? "1" : "0")]
        }
    }
}

/// A whole group's mute, addressed to its coordinator.
///
/// Mute only. The volume actions on this service exist, but they scale the members in
/// proportion - move a group at 80/40 up and one speaker travels twice as far as the other,
/// which is not what "turn the group up" means to anyone using it. Group volume is a uniform
/// adjustment written to each member instead; see `VolumeModel`.
///
/// Unlike `RenderingAction` these take no `Channel`: a group has no stereo channels of its
/// own, and sending one is how you get a 402 back.
enum GroupRenderingAction: SonosSOAPAction {
    case getGroupMute
    case setGroupMute(Bool)

    var service: SonosService { .groupRenderingControl }

    var name: String {
        switch self {
        case .getGroupMute: return "GetGroupMute"
        case .setGroupMute: return "SetGroupMute"
        }
    }

    var arguments: [(name: String, value: String)] {
        switch self {
        case .getGroupMute:
            return []
        case let .setGroupMute(muted):
            return [("DesiredMute", muted ? "1" : "0")]
        }
    }
}

/// Reads and writes volume. Every completion here lands on the main thread, because every
/// caller either drives UI state or is already main-thread-only.
enum VolumeControl {
    private static let log = Logger(subsystem: "com.curtisblackwell.sonos-controller", category: "volume")

    static let range = 0...100

    /// What one press of a volume key moves every speaker in the group by. macOS's own
    /// volume keys step by a sixteenth of the range, so this is deliberately close to what
    /// the same key does to the machine's speakers - a Sonos press that moved noticeably
    /// less would feel broken.
    static let keyStep = 6

    static func clamped(_ volume: Int) -> Int {
        min(max(volume, range.lowerBound), range.upperBound)
    }

    // MARK: - Group

    static func groupMute(coordinatorIP: String, completion: @escaping (Bool?) -> Void) {
        read(GroupRenderingAction.getGroupMute, named: "CurrentMute", from: coordinatorIP) { value in
            completion(value.map { $0 != 0 })
        }
    }

    static func setGroupMute(_ muted: Bool, coordinatorIP: String, completion: @escaping (Bool) -> Void = { _ in }) {
        write(GroupRenderingAction.setGroupMute(muted), to: coordinatorIP, completion: completion)
    }

    /// There is no toggle action, so this reads first. A read that fails does nothing rather
    /// than guessing: assuming "not muted" turns a dropped packet into a mute the user
    /// didn't ask for, and the next press would look like it did nothing.
    static func toggleGroupMute(coordinatorIP: String, completion: @escaping (Bool?) -> Void = { _ in }) {
        groupMute(coordinatorIP: coordinatorIP) { muted in
            guard let muted else {
                log.error("Could not read group mute from \(coordinatorIP, privacy: .public), ignoring the mute key")
                completion(nil)
                return
            }
            setGroupMute(!muted, coordinatorIP: coordinatorIP) { ok in
                completion(ok ? !muted : nil)
            }
        }
    }

    // MARK: - Room

    static func roomVolume(ip: String, completion: @escaping (Int?) -> Void) {
        read(RenderingAction.getVolume, named: "CurrentVolume", from: ip, completion: completion)
    }

    static func setRoomVolume(_ volume: Int, ip: String, completion: @escaping (Bool) -> Void = { _ in }) {
        write(RenderingAction.setVolume(volume), to: ip, completion: completion)
    }


    static func roomMute(ip: String, completion: @escaping (Bool?) -> Void) {
        read(RenderingAction.getMute, named: "CurrentMute", from: ip) { value in
            completion(value.map { $0 != 0 })
        }
    }

    static func setRoomMute(_ muted: Bool, ip: String, completion: @escaping (Bool) -> Void = { _ in }) {
        write(RenderingAction.setMute(muted), to: ip, completion: completion)
    }

    // MARK: - Transport

    private static func read(_ action: SonosSOAPAction, named element: String, from ip: String, completion: @escaping (Int?) -> Void) {
        SonosSOAP.send(action: action, to: ip) { result in
            let value = (try? result.get()).flatMap { SonosSOAP.intValue(named: element, in: $0) }
            DispatchQueue.main.async { completion(value) }
        }
    }

    private static func write(_ action: SonosSOAPAction, to ip: String, completion: @escaping (Bool) -> Void) {
        SonosSOAP.send(action: action, to: ip) { result in
            let ok: Bool
            switch result {
            case .success:
                ok = true
            case let .failure(error):
                log.error("\(action.name, privacy: .public) on \(ip, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                ok = false
            }
            DispatchQueue.main.async { completion(ok) }
        }
    }
}
