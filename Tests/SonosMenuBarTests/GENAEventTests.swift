import Testing
import Foundation
@testable import SonosMenuBar

struct GENAEventTests {
    private static let topologyXML = """
    <ZoneGroups>
      <ZoneGroup Coordinator="RINCON_LIVINGROOM01400" ID="RINCON_LIVINGROOM01400:1">
        <ZoneGroupMember UUID="RINCON_LIVINGROOM01400" ZoneName="Living Room" Location="http://192.168.1.50:1400/xml/device_description.xml"/>
        <ZoneGroupMember UUID="RINCON_KITCHEN01400" ZoneName="Kitchen" Location="http://192.168.1.51:1400/xml/device_description.xml"/>
      </ZoneGroup>
    </ZoneGroups>
    """

    private func escaped(_ xml: String) -> String {
        xml
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// A GENA event body: the same document GetZoneGroupState returns, in a propertyset
    /// rather than a SOAP envelope.
    private func eventBody(zoneGroupState: String) -> Data {
        Data("""
        <?xml version="1.0"?>
        <e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">
          <e:property><ZoneGroupState>\(zoneGroupState)</ZoneGroupState></e:property>
          <e:property><ThirdPartyMediaServersX></ThirdPartyMediaServersX></e:property>
        </e:propertyset>
        """.utf8)
    }

    @Test func parsesAnEventBody() {
        let groups = SonosTopology.parseGroups(fromEventBody: eventBody(zoneGroupState: escaped(Self.topologyXML)))
        #expect(groups.count == 1)
        #expect(groups.first?.displayName == "Living Room + Kitchen")
        #expect(groups.first?.coordinatorIP == "192.168.1.50")
    }

    @Test func parsesADoublyEscapedEventBody() {
        // Some firmware escapes the property value twice, so XMLParser's own unescape
        // leaves entities behind rather than markup.
        let body = eventBody(zoneGroupState: escaped(escaped(Self.topologyXML)))
        let groups = SonosTopology.parseGroups(fromEventBody: body)
        #expect(groups.count == 1)
        #expect(groups.first?.displayName == "Living Room + Kitchen")
    }

    @Test func parsesSiblingRootElements() {
        // <ZoneGroups> and <VanishedDevices> side by side is two roots, which XMLParser
        // rejects outright unless it is wrapped first.
        let state = escaped(Self.topologyXML + "\n<VanishedDevices/>")
        let groups = SonosTopology.parseGroups(fromEventBody: eventBody(zoneGroupState: state))
        #expect(groups.count == 1)
    }

    @Test func parsesAWrappedZoneGroupStateDocument() {
        let state = escaped("<ZoneGroupState>\(Self.topologyXML)<VanishedDevices/></ZoneGroupState>")
        let groups = SonosTopology.parseGroups(fromEventBody: eventBody(zoneGroupState: state))
        #expect(groups.count == 1)
    }

    @Test func unrelatedEventsParseToNothing() {
        // A ZoneGroupTopology subscription also delivers software-update properties; those
        // must not read as "the household is now empty".
        let body = Data("""
        <?xml version="1.0"?>
        <e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">
          <e:property><AvailableSoftwareUpdate>&lt;UpdateItem/&gt;</AvailableSoftwareUpdate></e:property>
        </e:propertyset>
        """.utf8)
        #expect(SonosTopology.parseGroups(fromEventBody: body).isEmpty)
    }

    @Test func garbageParsesToNothing() {
        #expect(SonosTopology.parseGroups(fromEventBody: Data("not xml at all".utf8)).isEmpty)
    }

    @Test func unescapingLeavesEscapedAmpersandsAlone() {
        // &amp;lt; is a literal "&lt;", not a "<": undoing &amp; first would invent markup.
        #expect(SonosTopology.unescapingXMLEntities("a &amp;lt; b") == "a &lt; b")
        #expect(SonosTopology.unescapingXMLEntities("&lt;tag attr=&quot;v&quot;/&gt;") == "<tag attr=\"v\"/>")
    }

    @Test func readsTheGrantedLeaseFromTheTimeoutHeader() {
        #expect(GENA.parseTimeout("Second-1800") == 1800)
        #expect(GENA.parseTimeout("second-60") == 60)
    }

    @Test func anUnusableTimeoutHeaderFallsBackToWhatWeAskedFor() {
        // Renewing sooner than needed is free; renewing too late loses events silently.
        let fallback = TimeInterval(GENA.requestedTimeout)
        #expect(GENA.parseTimeout(nil) == fallback)
        #expect(GENA.parseTimeout("infinite") == fallback)
        #expect(GENA.parseTimeout("Second-0") == fallback)
        #expect(GENA.parseTimeout("nonsense") == fallback)
    }
}
