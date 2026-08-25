import Testing
import Foundation
@testable import SonosMenuBar

struct ZoneGroupTopologyTests {
    /// GetZoneGroupState returns the topology document HTML-escaped inside the SOAP body.
    private func soapResponse(wrapping innerXML: String) -> String {
        let escaped = innerXML
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Body>
            <u:GetZoneGroupStateResponse xmlns:u="urn:schemas-upnp-org:service:ZoneGroupTopology:1">
              <ZoneGroupState>\(escaped)</ZoneGroupState>
            </u:GetZoneGroupStateResponse>
          </s:Body>
        </s:Envelope>
        """
    }

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
        let groups = SonosTopology.parseGroups(from: Data(soapResponse(wrapping: innerXML).utf8))
        #expect(groups.count == 2)

        let livingRoomGroup = groups.first { $0.id == "RINCON_LIVINGROOM01400" }
        #expect(livingRoomGroup?.displayName == "Living Room + Kitchen")
        #expect(livingRoomGroup?.coordinatorIP == "192.168.1.50")

        let officeGroup = groups.first { $0.id == "RINCON_OFFICE01400" }
        #expect(officeGroup?.displayName == "Office")
        #expect(officeGroup?.coordinatorIP == "192.168.1.52")
    }

    @Test func skipsInvisibleMembersAndZoneBridges() {
        let innerXML = """
        <ZoneGroups>
          <ZoneGroup Coordinator="RINCON_LIVINGROOM01400" ID="RINCON_LIVINGROOM01400:1">
            <ZoneGroupMember UUID="RINCON_LIVINGROOM01400" ZoneName="Living Room" Location="http://192.168.1.50:1400/xml/device_description.xml" Invisible="0"/>
            <ZoneGroupMember UUID="RINCON_PAIRED01400" ZoneName="Living Room (R)" Location="http://192.168.1.54:1400/xml/device_description.xml" Invisible="1"/>
          </ZoneGroup>
          <ZoneGroup Coordinator="RINCON_BOOST01400" ID="RINCON_BOOST01400:1">
            <ZoneGroupMember UUID="RINCON_BOOST01400" ZoneName="BOOST" Location="http://192.168.1.55:1400/xml/device_description.xml" IsZoneBridge="1" Invisible="1"/>
          </ZoneGroup>
        </ZoneGroups>
        """
        let groups = SonosTopology.parseGroups(from: Data(soapResponse(wrapping: innerXML).utf8))

        // The Boost group loses its only member, so it drops out entirely rather than
        // showing up as a selectable group whose commands go nowhere.
        #expect(groups.count == 1)
        #expect(groups.first?.displayName == "Living Room")
        #expect(groups.first?.coordinatorIP == "192.168.1.50")
    }

    @Test func surfacesEveryMemberWithUUIDAndIP() {
        let innerXML = """
        <ZoneGroups>
          <ZoneGroup Coordinator="RINCON_LIVINGROOM01400" ID="RINCON_LIVINGROOM01400:1">
            <ZoneGroupMember UUID="RINCON_LIVINGROOM01400" ZoneName="Living Room" Location="http://192.168.1.50:1400/xml/device_description.xml"/>
            <ZoneGroupMember UUID="RINCON_KITCHEN01400" ZoneName="Kitchen" Location="http://192.168.1.51:1400/xml/device_description.xml"/>
          </ZoneGroup>
        </ZoneGroups>
        """
        let groups = SonosTopology.parseGroups(from: Data(soapResponse(wrapping: innerXML).utf8))
        let group = try! #require(groups.first)

        // Coordinator first, then the rest by name - the order displayName reads in.
        #expect(group.members.map(\.name) == ["Living Room", "Kitchen"])
        #expect(group.members.map(\.uuid) == ["RINCON_LIVINGROOM01400", "RINCON_KITCHEN01400"])
        #expect(group.members.map(\.ipAddress) == ["192.168.1.50", "192.168.1.51"])
        #expect(group.coordinator?.uuid == "RINCON_LIVINGROOM01400")
        #expect(!group.isStandalone)
    }

    @Test func standaloneRoomIsAGroupOfOne() {
        let innerXML = """
        <ZoneGroups>
          <ZoneGroup Coordinator="RINCON_OFFICE01400" ID="RINCON_OFFICE01400:1">
            <ZoneGroupMember UUID="RINCON_OFFICE01400" ZoneName="Office" Location="http://192.168.1.52:1400/xml/device_description.xml"/>
          </ZoneGroup>
        </ZoneGroups>
        """
        let groups = SonosTopology.parseGroups(from: Data(soapResponse(wrapping: innerXML).utf8))
        #expect(groups.first?.isStandalone == true)
        #expect(groups.first?.displayName == "Office")
    }

    @Test func allRoomsFlattensAndSortsByName() {
        let innerXML = """
        <ZoneGroups>
          <ZoneGroup Coordinator="RINCON_LIVINGROOM01400" ID="RINCON_LIVINGROOM01400:1">
            <ZoneGroupMember UUID="RINCON_LIVINGROOM01400" ZoneName="Living Room" Location="http://192.168.1.50:1400/xml/device_description.xml"/>
            <ZoneGroupMember UUID="RINCON_KITCHEN01400" ZoneName="Kitchen" Location="http://192.168.1.51:1400/xml/device_description.xml"/>
          </ZoneGroup>
          <ZoneGroup Coordinator="RINCON_OFFICE01400" ID="RINCON_OFFICE01400:1">
            <ZoneGroupMember UUID="RINCON_OFFICE01400" ZoneName="Office" Location="http://192.168.1.52:1400/xml/device_description.xml"/>
          </ZoneGroup>
        </ZoneGroups>
        """
        let groups = SonosTopology.parseGroups(from: Data(soapResponse(wrapping: innerXML).utf8))
        #expect(SonosTopology.allRooms(in: groups).map(\.name) == ["Kitchen", "Living Room", "Office"])
    }

    @Test func dropsGroupWhoseCoordinatorHasNoUsableLocation() {
        // Coordinator is present but its Location has no host, so there is nowhere to send
        // the group's transport commands.
        let innerXML = """
        <ZoneGroups>
          <ZoneGroup Coordinator="RINCON_BROKEN01400" ID="RINCON_BROKEN01400:1">
            <ZoneGroupMember UUID="RINCON_BROKEN01400" ZoneName="Broken" Location="not-a-url"/>
            <ZoneGroupMember UUID="RINCON_KITCHEN01400" ZoneName="Kitchen" Location="http://192.168.1.51:1400/xml/device_description.xml"/>
          </ZoneGroup>
        </ZoneGroups>
        """
        #expect(SonosTopology.parseGroups(from: Data(soapResponse(wrapping: innerXML).utf8)).isEmpty)
    }

    @Test func returnsEmptyOnMalformedResponse() {
        let groups = SonosTopology.parseGroups(from: Data("not xml".utf8))
        #expect(groups.isEmpty)
    }
}
