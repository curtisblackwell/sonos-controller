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
    case getPositionInfo
    /// Restarts current track from beginning - `previous()` uses this instead of `.previous`
    /// once playback is more than a few seconds in, matching how physical transport controls
    /// on other players behave.
    case seek(target: String)
    /// Jumps to a position in the queue. Same `Seek` action as above but a different unit, so
    /// the target is a 1-based track number rather than a time.
    case seekTrack(number: Int)
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
    /// Puts one track in the queue. `desiredFirstTrackNumber` 0 means "append"; a real
    /// position inserts there. `enqueueAsNext` inserts after the current track instead.
    case addURIToQueue(uri: String, metadata: String, desiredFirstTrackNumber: Int, enqueueAsNext: Bool)
    /// `objectID` is a queue item's own id, `Q:0/<n>`. `updateID` 0 means "whatever the queue
    /// is now" - Sonos accepts it, and tracking the real value would mean re-reading the queue
    /// before every removal to guard against a race the user cannot lose in practice.
    case removeTrackFromQueue(objectID: String, updateID: Int)
    case removeAllTracksFromQueue

    var service: SonosService { .avTransport }

    var name: String {
        switch self {
        case .play: return "Play"
        case .pause: return "Pause"
        case .next: return "Next"
        case .previous: return "Previous"
        case .getTransportInfo: return "GetTransportInfo"
        case .getPositionInfo: return "GetPositionInfo"
        case .seek, .seekTrack: return "Seek"
        case .setAVTransportURI: return "SetAVTransportURI"
        case .becomeCoordinatorOfStandaloneGroup: return "BecomeCoordinatorOfStandaloneGroup"
        case .delegateGroupCoordinationTo: return "DelegateGroupCoordinationTo"
        case .addURIToQueue: return "AddURIToQueue"
        case .removeTrackFromQueue: return "RemoveTrackFromQueue"
        case .removeAllTracksFromQueue: return "RemoveAllTracksFromQueue"
        }
    }

    /// Arguments after `InstanceID`, in the order the service expects them.
    var arguments: [(name: String, value: String)] {
        switch self {
        case .play:
            return [("Speed", "1")]
        case .pause, .next, .previous, .getTransportInfo, .getPositionInfo,
             .becomeCoordinatorOfStandaloneGroup, .removeAllTracksFromQueue:
            return []
        case let .seek(target):
            return [("Unit", "REL_TIME"), ("Target", target)]
        case let .seekTrack(number):
            return [("Unit", "TRACK_NR"), ("Target", String(number))]
        case let .setAVTransportURI(uri, metadata):
            return [("CurrentURI", uri), ("CurrentURIMetaData", metadata)]
        case let .delegateGroupCoordinationTo(newCoordinator, rejoinGroup):
            return [("NewCoordinator", newCoordinator), ("RejoinGroup", rejoinGroup ? "1" : "0")]
        case let .addURIToQueue(uri, metadata, desiredFirstTrackNumber, enqueueAsNext):
            return [
                ("EnqueuedURI", uri),
                ("EnqueuedURIMetaData", metadata),
                ("DesiredFirstTrackNumberEnqueued", String(desiredFirstTrackNumber)),
                ("EnqueueAsNext", enqueueAsNext ? "1" : "0"),
            ]
        case let .removeTrackFromQueue(objectID, updateID):
            return [("ObjectID", objectID), ("UpdateID", String(updateID))]
        }
    }
}

/// Kept as the name the grouping code reports failures under; the cases themselves moved to
/// `SonosSOAPError` when the transport was shared with the volume services.
typealias SonosControlError = SonosSOAPError

/// What's playing, as read from `GetPositionInfo`'s `TrackMetaData`. Every field is nil rather
/// than empty when the source doesn't provide it, so the view can tell "no album" from "not
/// read yet".
struct TrackMetadata: Equatable {
    let title: String?
    let artist: String?
    let album: String?
    let albumArtURL: URL?
}

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

    static func relTimeSeconds(from data: Data) -> Int? {
        SonosSOAP.timeSeconds(named: "RelTime", in: data)
    }

    static func trackDurationSeconds(from data: Data) -> Int? {
        SonosSOAP.timeSeconds(named: "TrackDuration", in: data)
    }

    /// Title, artist, album, and album art pulled out of a `GetPositionInfo` response's
    /// `TrackMetaData` - DIDL-Lite XML, escaped once into the SOAP body.
    ///
    /// `coordinatorIP` resolves `upnp:albumArtURI`, which Sonos gives back as a path
    /// (`/getaa?...`) relative to the player serving the art rather than an absolute URL -
    /// shared with the browse lists via `DIDL.artURL`, since both read the same field.
    static func trackMetadata(from data: Data, coordinatorIP: String) -> TrackMetadata? {
        guard let raw = SonosSOAP.value(named: "TrackMetaData", in: data), raw != "NOT_IMPLEMENTED" else {
            return nil
        }
        let didl = SonosSOAP.xmlUnescaped(raw)
        let title = SonosSOAP.value(named: "dc:title", inXML: didl)
        let artist = SonosSOAP.value(named: "dc:creator", inXML: didl)
        let album = SonosSOAP.value(named: "upnp:album", inXML: didl)
        let albumArtURL = DIDL.artURL(
            from: SonosSOAP.value(named: "upnp:albumArtURI", inXML: didl),
            coordinatorIP: coordinatorIP
        )
        guard title != nil || artist != nil || album != nil || albumArtURL != nil else { return nil }
        return TrackMetadata(title: title, artist: artist, album: album, albumArtURL: albumArtURL)
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
