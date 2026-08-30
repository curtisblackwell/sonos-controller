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

    /// The household's content: favorites, Sonos playlists, the queue, the local library
    /// index. Lives on the MediaServer half of the player rather than the MediaRenderer, and
    /// - unlike the three above - its actions take no `InstanceID`.
    static let contentDirectory = SonosService(
        type: "urn:schemas-upnp-org:service:ContentDirectory:1",
        controlPath: "/MediaServer/ContentDirectory/Control"
    )

    /// Which music services exist, and what numeric id each one has. Needed because a
    /// service id is not a constant: it varies by region and account, so anything that builds
    /// a service URI has to look it up rather than hardcode it.
    static let musicServices = SonosService(
        type: "urn:schemas-upnp-org:service:MusicServices:1",
        controlPath: "/MusicServices/Control"
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
    /// Whether `InstanceID` leads the argument list. True for the three MediaRenderer
    /// services, where every action takes it; false for ContentDirectory and MusicServices,
    /// which reject it.
    var includesInstanceID: Bool { get }
}

extension SonosSOAPAction {
    var includesInstanceID: Bool { true }
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

    /// `InstanceID` 0 is hardcoded because every action on the MediaRenderer services takes
    /// it first and Sonos has exactly one instance per player - there is no second value it
    /// could ever be. ContentDirectory and MusicServices don't take it at all, and say so by
    /// returning false from `includesInstanceID`.
    static func envelope(action: SonosSOAPAction) -> String {
        let instance = action.includesInstanceID ? "<InstanceID>0</InstanceID>" : ""
        let extra = action.arguments
            .map { "<\($0.name)>\(xmlEscaped($0.value))</\($0.name)>" }
            .joined()
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body><u:\(action.name) xmlns:u="\(action.service.type)">\(instance)\(extra)</u:\(action.name)></s:Body>
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

    /// `TrackMetaData` comes back as DIDL-Lite XML escaped once into the SOAP body - this
    /// undoes that so its own tags (`dc:title`, `upnp:albumArtURI`, ...) can be scanned the
    /// same way `value(named:in:)` scans the outer response.
    static func xmlUnescaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
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

    /// Same flat scan as `value(named:in:)`, over an XML string already in hand - `TrackMetaData`
    /// arrives as one after `value(named:in:)` and `xmlUnescaped` have already run once.
    static func value(named name: String, inXML text: String) -> String? {
        guard let start = text.range(of: "<\(name)>"),
              let end = text.range(of: "</\(name)>"),
              start.upperBound <= end.lowerBound
        else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }

    /// `RelTime` and `TrackDuration` both come back as `H:MM:SS` (or `HH:MM:SS`), never plain
    /// seconds.
    static func timeSeconds(named name: String, in data: Data) -> Int? {
        guard let text = value(named: name, in: data) else { return nil }
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    /// The inverse of `timeSeconds(named:in:)`, for building a `Seek` target.
    static func formatTime(seconds: Int) -> String {
        let seconds = max(seconds, 0)
        return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
}
