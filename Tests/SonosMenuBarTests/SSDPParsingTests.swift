import Testing
import Foundation
@testable import SonosMenuBar

struct SSDPParsingTests {
    @Test func parsesLocationHeader() {
        let response = "HTTP/1.1 200 OK\r\n" +
            "CACHE-CONTROL: max-age=1800\r\n" +
            "LOCATION: http://192.168.1.50:1400/xml/device_description.xml\r\n" +
            "ST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n" +
            "\r\n"

        let location = SonosDiscovery.parseLocationHeader(from: response)
        #expect(location == "http://192.168.1.50:1400/xml/device_description.xml")
    }

    @Test func parsesLocationHeaderCaseInsensitive() {
        let response = "HTTP/1.1 200 OK\r\nlocation: http://10.0.0.5:1400/xml/device_description.xml\r\n\r\n"
        let location = SonosDiscovery.parseLocationHeader(from: response)
        #expect(location == "http://10.0.0.5:1400/xml/device_description.xml")
    }

    @Test func returnsNilWhenNoLocationHeader() {
        let response = "HTTP/1.1 200 OK\r\nST: something-else\r\n\r\n"
        #expect(SonosDiscovery.parseLocationHeader(from: response) == nil)
    }

    @Test func parsesDeviceDescriptionXML() {
        let xml = """
        <?xml version="1.0"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0">
          <device>
            <deviceType>urn:schemas-upnp-org:device:ZonePlayer:1</deviceType>
            <roomName>Living Room</roomName>
            <UDN>uuid:RINCON_ABC123</UDN>
          </device>
        </root>
        """
        let parser = DeviceDescriptionParser()
        #expect(parser.parse(data: Data(xml.utf8)))
        #expect(parser.roomName == "Living Room")
        #expect(parser.udn == "uuid:RINCON_ABC123")
        #expect(parser.deviceType.contains("ZonePlayer"))
    }
}

struct MulticastInterfaceTests {
    /// Can't assert a specific address - this just pins the invariants the M-SEARCH send
    /// path relies on: no loopback (127.x) and no duplicate interface addresses, since
    /// each one costs an extra datagram per search.
    @Test func excludesLoopbackAndDuplicates() {
        let addresses = SonosDiscovery.multicastInterfaceAddresses()
        let octets = addresses.map { UInt32(bigEndian: $0.s_addr) >> 24 }
        #expect(!octets.contains(127))
        #expect(Set(addresses.map(\.s_addr)).count == addresses.count)
    }
}
