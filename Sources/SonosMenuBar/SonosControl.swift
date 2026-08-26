import Foundation
import os.log

/// An AVTransport action. Every one of these takes `InstanceID` 0; the associated values
/// are the action-specific arguments that follow it in the SOAP body.
enum SonosAction: SonosSOAPAction {
    case play
    case pause
    case next
    case previous
    case getTransportInfo
    /// Grouping: pointing a player at `x-rincon:<coordinatorUUID>` makes it join that
    /// player's group. Also the normal way to set a playback source.
    case setAVTransportURI(uri: String, metadata: String)
    /// Grouping: pulls a *non-coordinating* player out of whatever group it is in.
    /// Sending this to a player that already coordinates its group does nothing at all -
    /// use `delegateGroupCoordinationTo` for that case.
    case becomeCoordinatorOfStandaloneGroup
    /// Grouping: hands coordination of a group to another member. With `rejoinGroup` false
    /// the old coordinator drops out, which is the only way to remove a coordinator from a
    /// group that should carry on without it.
    case delegateGroupCoordinationTo(newCoordinator: String, rejoinGroup: Bool)

    var service: SonosService { .avTransport }

    var name: String {
        switch self {
        case .play: return "Play"
        case .pause: return "Pause"
        case .next: return "Next"
        case .previous: return "Previous"
        case .getTransportInfo: return "GetTransportInfo"
        case .setAVTransportURI: return "SetAVTransportURI"
        case .becomeCoordinatorOfStandaloneGroup: return "BecomeCoordinatorOfStandaloneGroup"
        case .delegateGroupCoordinationTo: return "DelegateGroupCoordinationTo"
        }
    }

    /// Arguments after `InstanceID`, in the order the service expects them.
    var arguments: [(name: String, value: String)] {
        switch self {
        case .play:
            return [("Speed", "1")]
        case .pause, .next, .previous, .getTransportInfo, .becomeCoordinatorOfStandaloneGroup:
            return []
        case let .setAVTransportURI(uri, metadata):
            return [("CurrentURI", uri), ("CurrentURIMetaData", metadata)]
        case let .delegateGroupCoordinationTo(newCoordinator, rejoinGroup):
            return [("NewCoordinator", newCoordinator), ("RejoinGroup", rejoinGroup ? "1" : "0")]
        }
    }
}

/// Kept as the name the grouping code reports failures under; the cases themselves moved to
/// `SonosSOAPError` when the transport was shared with the volume services.
typealias SonosControlError = SonosSOAPError

enum SonosControl {
    private static let log = Logger(subsystem: "com.curtisblackwell.sonos-controller", category: "control")

    static var requestTimeout: TimeInterval { SonosSOAP.requestTimeout }

    static func soapEnvelope(action: SonosAction) -> String {
        SonosSOAP.envelope(action: action)
    }

    static func xmlEscaped(_ value: String) -> String {
        SonosSOAP.xmlEscaped(value)
    }

    static func controlURL(ip: String) -> URL? {
        SonosService.avTransport.controlURL(ip: ip)
    }

    static func send(action: SonosAction, to ip: String, completion: ((Data?) -> Void)? = nil) {
        send(action: action, to: ip) { (result: Result<Data, Error>) in
            completion?(try? result.get())
        }
    }

    /// The grouping editor needs to know whether a command actually landed - a silently
    /// dropped join leaves the UI showing a grouping that never happened - so this variant
    /// surfaces the failure instead of only logging it.
    static func send(action: SonosAction, to ip: String, completion: @escaping (Result<Data, Error>) -> Void) {
        SonosSOAP.send(action: action, to: ip, completion: completion)
    }

    static func currentTransportState(from data: Data) -> String? {
        SonosSOAP.value(named: "CurrentTransportState", in: data)
    }

    /// Toggling needs to know the current state, and there is no "toggle" UPnP action.
    /// If GetTransportInfo fails or comes back unparseable we do nothing rather than
    /// assume "not playing" - guessing turns a dropped packet mid-playback into a Play,
    /// so the pause press appears to be ignored.
    static func togglePlayPause(ip: String) {
        send(action: .getTransportInfo, to: ip) { data in
            guard let state = data.flatMap(currentTransportState) else {
                log.error("Could not read transport state from \(ip, privacy: .public), ignoring play/pause")
                return
            }
            let isPlaying = state == "PLAYING" || state == "TRANSITIONING"
            send(action: isPlaying ? .pause : .play, to: ip)
        }
    }
}
