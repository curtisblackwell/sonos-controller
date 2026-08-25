import Testing
import Foundation
@testable import SonosMenuBar

struct ZoneGroupTopologyTests {
    @Test func parsesGroupedAndStandaloneRooms() {
        let innerXML = """
        <ZoneGroups>
          <ZoneGroup Coordinator="RINCON_LIVINGROOM01400" ID="RINCON_LIVINGROOM01400:1">
            <ZoneGroupMember UUID="RINCON_LIVINGROOM01400" ZoneName="Living Room" Location="http://192.168.1.50:1400/xml/device_description.xml"/>
            <ZoneGroupMember UUID="RINCON_KITCHEN01400" ZoneName="Kitchen" Location="http://192.168.1.51:1400/xml/device_description.xml"/>
          </ZoneGroup>
          <ZoneGroup Coordinator="RINCON_OFFICE01400" ID="RINCON_OFFICE01400:1">
            <ZoneGroupMember UUID="RINCON_OFFICE01400" ZoneName="Office" Location="http://192.168.1.52:1400/xml/device_description.xml">
              <Satellite UUID="RINCON_OFFICESUB01400" ZoneName="Office" Location="http://192.168.1.53:1400/xml/device_description.xml"/>
            </ZoneGroupMember>
          </ZoneGroup>
        </ZoneGroups>
        """
        let escaped = innerXML
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")

        let soapResponse = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Body>
            <u:GetZoneGroupStateResponse xmlns:u="urn:schemas-upnp-org:service:ZoneGroupTopology:1">
              <ZoneGroupState>\(escaped)</ZoneGroupState>
            </u:GetZoneGroupStateResponse>
          </s:Body>
        </s:Envelope>
        """

        let groups = SonosTopology.parseGroups(from: Data(soapResponse.utf8))
        #expect(groups.count == 2)

        let livingRoomGroup = groups.first { $0.id == "RINCON_LIVINGROOM01400" }
        #expect(livingRoomGroup?.displayName == "Living Room + Kitchen")
        #expect(livingRoomGroup?.coordinatorIP == "192.168.1.50")

        let officeGroup = groups.first { $0.id == "RINCON_OFFICE01400" }
        #expect(officeGroup?.displayName == "Office")
        #expect(officeGroup?.coordinatorIP == "192.168.1.52")
    }

    @Test func returnsEmptyOnMalformedResponse() {
        let groups = SonosTopology.parseGroups(from: Data("not xml".utf8))
        #expect(groups.isEmpty)
    }
}
