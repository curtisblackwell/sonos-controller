import Foundation
import os.log

/// A UPnP service on a Sonos player: where its control endpoint lives, and the type string
/// that has to appear both inside the envelope and in the `SOAPACTION` header.
struct SonosService {
    let type: String
    let controlPath: String

    /// Transport: play, pause, skip - and, because grouping is expressed as a playback
    /// source, every grouping command too.
    static let avTransport = SonosService(
        type: "urn:schemas-upnp-org:service:AVTransport:1",
        controlPath: "/MediaRenderer/AVTransport/Control"
    )

    /// One player's own volume and mute. Addressed to that player, whether or not it
    /// coordinates a group.
    static let renderingControl = SonosService(
        type: "urn:schemas-upnp-org:service:RenderingControl:1",
        controlPath: "/MediaRenderer/RenderingControl/Control"
    )

    /// A whole group's mute, addressed to its coordinator. Only mute: the volume half of
    /// this service moves members in proportion rather than by equal amounts, so a group at
    /// 80/40 nudged up moves one speaker twice as far as the other. Mute has no amount to
    /// get wrong, and one call beats one per member.
    static let groupRenderingControl = SonosService(
        type: "urn:schemas-upnp-org:service:GroupRenderingControl:1",
        controlPath: "/MediaRenderer/GroupRenderingControl/Control"
    )

    func controlURL(ip: String) -> URL? {
        URL(string: "http://\(ip):1400\(controlPath)")
    }
}

/// One SOAP action: the name that goes in both the envelope and the `SOAPACTION` header,
/// and the arguments that follow `InstanceID` in the body, in the order the service wants
/// them.
protocol SonosSOAPAction {
    var service: SonosService { get }
    var name: String { get }
    var arguments: [(name: String, value: String)] { get }
}

enum SonosSOAPError: LocalizedError {
    case invalidAddress(String)
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case let .invalidAddress(ip): return "Couldn't build a control URL for \(ip)."
        case let .httpStatus(code): return "The speaker returned HTTP \(code)."
        }
    }
}

/// The one place a SOAP request is built and sent. Every Sonos service this app talks to
/// takes the same shape, so the transport, the timeout, and the escaping live here rather
/// than once per service.
enum SonosSOAP {
    private static let log = Logger(subsystem: "com.curtisblackwell.sonos-controller", category: "soap")

    /// Every speaker we talk to is on the LAN, so a reply is either quick or never coming.
    /// URLSession's 60s default means one unplugged player holds a request open for a full
    /// minute, which is long enough for anything serialized behind it to look like a hang.
    static let requestTimeout: TimeInterval = 5

    /// `InstanceID` 0 is hardcoded because every action on all three of these services takes
    /// it first and Sonos has exactly one instance per player - there is no second value it
    /// could ever be.
    static func envelope(action: SonosSOAPAction) -> String {
        let extra = action.arguments
            .map { "<\($0.name)>\(xmlEscaped($0.value))</\($0.name)>" }
            .joined()
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body><u:\(action.name) xmlns:u="\(action.service.type)"><InstanceID>0</InstanceID>\(extra)</u:\(action.name)></s:Body>
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

    /// Completion runs on a URLSession queue, not the main thread - callers that touch UI
    /// state hop for themselves.
    static func send(action: SonosSOAPAction, to ip: String, completion: @escaping (Result<Data, Error>) -> Void) {
        guard let url = action.service.controlURL(ip: ip) else {
            completion(.failure(SonosSOAPError.invalidAddress(ip)))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(action.service.type)#\(action.name)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(envelope(action: action).utf8)
        request.timeoutInterval = requestTimeout

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                log.error("Sonos \(action.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                completion(.failure(error))
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                log.error("Sonos \(action.name, privacy: .public) returned HTTP \(http.statusCode)")
                completion(.failure(SonosSOAPError.httpStatus(http.statusCode)))
                return
            }
            completion(.success(data ?? Data()))
        }.resume()
    }

    /// Pulls one out-argument's text out of a response body. These replies are flat -
    /// `<CurrentVolume>42</CurrentVolume>` inside the envelope, no nesting and no attributes
    /// - so a scan for the tag beats standing an XMLParser delegate up for each one.
    ///
    /// The bounds check isn't ceremony: on a body where the closing tag appears first, the
    /// range would run backwards and slicing it traps.
    static func value(named name: String, in data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let start = text.range(of: "<\(name)>"),
              let end = text.range(of: "</\(name)>"),
              start.upperBound <= end.lowerBound
        else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }

    static func intValue(named name: String, in data: Data) -> Int? {
        value(named: name, in: data).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
