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
        let extractor = ZoneGroupStateExtractor()
        let outerParser = XMLParser(data: responseData)
        outerParser.delegate = extractor
        guard outerParser.parse(), !extractor.zoneGroupStateXML.isEmpty else { return [] }

        let topology = ZoneGroupTopologyParser()
        guard topology.parse(xmlString: extractor.zoneGroupStateXML) else { return [] }

        return topology.groups.compactMap { group -> SonosGroup? in
            guard let coordinator = group.members.first(where: { $0.uuid == group.coordinatorUUID }),
                  let coordinatorIP = URL(string: coordinator.location)?.host else { return nil }
            let otherNames = group.members
                .filter { $0.uuid != group.coordinatorUUID }
                .map(\.zoneName)
                .sorted()
            let displayName = ([coordinator.zoneName] + otherNames).joined(separator: " + ")
            return SonosGroup(id: group.coordinatorUUID, displayName: displayName, coordinatorIP: coordinatorIP)
        }
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
