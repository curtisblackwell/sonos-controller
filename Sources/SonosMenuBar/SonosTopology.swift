import Foundation
import os.log

/// Resolves Sonos group topology (which rooms are grouped, and which member is the
/// coordinator that AVTransport commands must target) via the ZoneGroupTopology service.
/// Any single reachable ZonePlayer can answer this for the whole household.
enum SonosTopology {
    private static let log = Logger(subsystem: "com.curtis.sonos-controller", category: "topology")

    static func controlURL(ip: String) -> URL? {
        URL(string: "http://\(ip):1400/ZoneGroupTopology/Control")
    }

    static func soapEnvelope() -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body><u:GetZoneGroupState xmlns:u="urn:schemas-upnp-org:service:ZoneGroupTopology:1"></u:GetZoneGroupState></s:Body>
        </s:Envelope>
        """
    }

    static func fetchGroups(from ip: String, completion: @escaping ([SonosGroup]) -> Void) {
        guard let url = controlURL(ip: ip) else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:ZoneGroupTopology:1#GetZoneGroupState\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(soapEnvelope().utf8)

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data, error == nil else {
                log.error("GetZoneGroupState failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
                DispatchQueue.main.async { completion([]) }
                return
            }
            let groups = parseGroups(from: data)
            DispatchQueue.main.async { completion(groups) }
        }.resume()
    }

    static func parseGroups(from responseData: Data) -> [SonosGroup] {
        parseGroups(zoneGroupStateXML: extractZoneGroupState(from: responseData))
    }

    /// The same service pushes the topology to GENA subscribers as an event. The body is a
    /// UPnP propertyset rather than a SOAP envelope, but the `ZoneGroupState` property it
    /// carries is the identical document - so only the wrapper differs.
    static func parseGroups(fromEventBody body: Data) -> [SonosGroup] {
        parseGroups(zoneGroupStateXML: extractZoneGroupState(from: body))
    }

    /// Pulls the `ZoneGroupState` element's text out of whatever wrapper it arrived in.
    /// XMLParser hands text back already unescaped once, which is usually enough.
    private static func extractZoneGroupState(from data: Data) -> String {
        let extractor = ZoneGroupStateExtractor()
        let parser = XMLParser(data: data)
        parser.delegate = extractor
        guard parser.parse() else { return "" }
        return extractor.zoneGroupStateXML
    }

    private static func parseGroups(zoneGroupStateXML: String) -> [SonosGroup] {
        var xml = zoneGroupStateXML
        guard !xml.isEmpty else { return [] }
        // Some firmware escapes the property value twice, so the single unescape XMLParser
        // does leaves entities behind. A document that has been unescaped enough always has
        // real ZoneGroup tags in it, so their absence is the reliable tell.
        if !xml.contains("<ZoneGroup") { xml = unescapingXMLEntities(xml) }

        let topology = ZoneGroupTopologyParser()
        guard topology.parse(xmlString: xml) else { return [] }

        return topology.groups.compactMap { group -> SonosGroup? in
            let rooms = group.members.compactMap { member -> SonosRoom? in
                guard let ip = URL(string: member.location)?.host else { return nil }
                return SonosRoom(uuid: member.uuid, name: member.zoneName, ipAddress: ip)
            }
            // A group whose coordinator we can't reach is unusable - we'd have nowhere to
            // send its transport commands - so drop it rather than list it.
            guard let coordinator = rooms.first(where: { $0.uuid == group.coordinatorUUID }) else { return nil }
            let others = rooms
                .filter { $0.uuid != group.coordinatorUUID }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return SonosGroup(
                id: group.coordinatorUUID,
                coordinatorIP: coordinator.ipAddress,
                members: [coordinator] + others
            )
        }
    }

    /// `&amp;` is undone last: doing it first would turn an escaped `&amp;lt;` into a live
    /// `<` and invent markup that was never in the document.
    static func unescapingXMLEntities(_ string: String) -> String {
        var result = string
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result
    }

    /// Every controllable room in the household, sorted by name. The editor needs this flat
    /// view as well as the grouped one.
    static func allRooms(in groups: [SonosGroup]) -> [SonosRoom] {
        groups
            .flatMap(\.members)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Pulls the (HTML-entity-escaped) inner topology XML out of the SOAP response body.
/// XMLParser hands us already-unescaped text via foundCharacters, which is exactly
/// the raw <ZoneGroups>...</ZoneGroups> document we need to parse next.
private final class ZoneGroupStateExtractor: NSObject, XMLParserDelegate {
    private(set) var zoneGroupStateXML = ""
    private var capturing = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "ZoneGroupState" { capturing = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { zoneGroupStateXML += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "ZoneGroupState" { capturing = false }
    }
}

private final class ZoneGroupTopologyParser: NSObject, XMLParserDelegate {
    struct Member {
        let uuid: String
        let zoneName: String
        let location: String
    }
    struct RawGroup {
        let coordinatorUUID: String
        let members: [Member]
    }

    private(set) var groups: [RawGroup] = []
    private var currentCoordinatorUUID = ""
    private var currentMembers: [Member] = []

    func parse(xmlString: String) -> Bool {
        if parseDocument(xmlString) { return true }
        // Some firmware sends <ZoneGroups> and <VanishedDevices> as siblings, which is two
        // root elements and not a document XMLParser will accept. Only pay for the wrapper
        // after a real failure, and start from a clean slate - a parse that died partway
        // through will have left groups behind.
        groups = []
        currentMembers = []
        currentCoordinatorUUID = ""
        return parseDocument("<SonosZoneGroupState>\(xmlString)</SonosZoneGroupState>")
    }

    private func parseDocument(_ xmlString: String) -> Bool {
        guard let data = xmlString.data(using: .utf8) else { return false }
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "ZoneGroup":
            currentCoordinatorUUID = attributeDict["Coordinator"] ?? ""
            currentMembers = []
        case "ZoneGroupMember":
            // Nested <Satellite> elements (bonded rears/subs) are a different tag name
            // and are intentionally skipped - they aren't independently controllable rooms.
            // Members flagged Invisible="1" (paired-away players) and IsZoneBridge="1"
            // (Boost/Bridge) come through as ordinary ZoneGroupMembers but have no
            // playback of their own, so listing them would offer groups that ignore
            // every transport command sent to them.
            guard attributeDict["Invisible"] != "1", attributeDict["IsZoneBridge"] != "1" else { break }
            if let uuid = attributeDict["UUID"], let zoneName = attributeDict["ZoneName"], let location = attributeDict["Location"] {
                currentMembers.append(Member(uuid: uuid, zoneName: zoneName, location: location))
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "ZoneGroup" {
            groups.append(RawGroup(coordinatorUUID: currentCoordinatorUUID, members: currentMembers))
        }
    }
}
