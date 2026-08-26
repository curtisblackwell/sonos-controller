import Foundation
import os.log

/// An AVTransport action. Every one of these takes `InstanceID` 0; the associated values
/// are the action-specific arguments that follow it in the SOAP body.
enum SonosAction {
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
    fileprivate var arguments: [(name: String, value: String)] {
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

enum SonosControlError: LocalizedError {
    case invalidAddress(String)
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case let .invalidAddress(ip): return "Couldn't build a control URL for \(ip)."
        case let .httpStatus(code): return "The speaker returned HTTP \(code)."
        }
    }
}

enum SonosControl {
    private static let log = Logger(subsystem: "com.curtisblackwell.sonos-controller", category: "control")

    /// Every speaker we talk to is on the LAN, so a reply is either quick or never coming.
    /// URLSession's 60s default means one unplugged player holds a request open for a full
    /// minute, which is long enough for anything serialized behind it to look like a hang.
    static let requestTimeout: TimeInterval = 5

    static func soapEnvelope(action: SonosAction) -> String {
        let extra = action.arguments
            .map { "<\($0.name)>\(xmlEscaped($0.value))</\($0.name)>" }
            .joined()
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body><u:\(action.name) xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID>\(extra)</u:\(action.name)></s:Body>
        </s:Envelope>
        """
    }

    /// `x-rincon:` URIs contain nothing that needs escaping, but DIDL-Lite metadata and
    /// arbitrary playback URIs do, and the envelope builder shouldn't be the thing that
    /// breaks the first time one is passed in.
    static func xmlEscaped(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&apos;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    static func controlURL(ip: String) -> URL? {
        URL(string: "http://\(ip):1400/MediaRenderer/AVTransport/Control")
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
        guard let url = controlURL(ip: ip) else {
            completion(.failure(SonosControlError.invalidAddress(ip)))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#\(action.name)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(soapEnvelope(action: action).utf8)
        request.timeoutInterval = requestTimeout

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                log.error("Sonos \(action.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                completion(.failure(error))
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                log.error("Sonos \(action.name, privacy: .public) returned HTTP \(http.statusCode)")
                completion(.failure(SonosControlError.httpStatus(http.statusCode)))
                return
            }
            completion(.success(data ?? Data()))
        }.resume()
    }

    static func currentTransportState(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let start = text.range(of: "<CurrentTransportState>"),
              let end = text.range(of: "</CurrentTransportState>") else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
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
