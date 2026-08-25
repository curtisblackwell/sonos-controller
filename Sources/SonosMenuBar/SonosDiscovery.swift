import Foundation
import os.log

final class SonosDiscovery: NSObject {
    private static let log = Logger(subsystem: "com.curtis.sonos-controller", category: "discovery")
    private static let ssdpAddress = "239.255.255.250"
    private static let ssdpPort: UInt16 = 1900
    private static let searchTarget = "urn:schemas-upnp-org:device:ZonePlayer:1"

    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var discoveredLocations: Set<URL> = []

    /// Runs an SSDP search for ~3s, resolves each responding device's description XML,
    /// then calls completion once on the main thread with the deduped device list.
    func discover(completion: @escaping ([SonosDevice]) -> Void) {
        discoveredLocations = []
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            Self.log.error("Failed to create SSDP socket")
            DispatchQueue.main.async { completion([]) }
            return
        }
        socketFD = fd

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler { [weak self] in
            self?.readAvailableData()
        }
        source.resume()
        readSource = source

        sendSearch(fd: fd)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.sendSearch(fd: fd)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.sendSearch(fd: fd)
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.finishListening { locations in
                self?.resolveDevices(locations: locations, completion: completion)
            }
        }
    }

    private func sendSearch(fd: Int32) {
        let message = "M-SEARCH * HTTP/1.1\r\n" +
            "HOST: \(Self.ssdpAddress):\(Self.ssdpPort)\r\n" +
            "MAN: \"ssdp:discover\"\r\n" +
            "MX: 2\r\n" +
            "ST: \(Self.searchTarget)\r\n" +
            "\r\n"
        guard let data = message.data(using: .utf8) else { return }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.ssdpPort.bigEndian
        addr.sin_addr.s_addr = inet_addr(Self.ssdpAddress)

        _ = data.withUnsafeBytes { buffer -> Int in
            withUnsafePointer(to: &addr) { ptr -> Int in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    sendto(fd, buffer.baseAddress, buffer.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func readAvailableData() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = recv(socketFD, &buffer, buffer.count, 0)
        guard count > 0, let text = String(bytes: buffer[0..<count], encoding: .utf8) else { return }
        guard let location = Self.parseLocationHeader(from: text), let url = URL(string: location) else { return }
        discoveredLocations.insert(url)
    }

    static func parseLocationHeader(from response: String) -> String? {
        for line in response.split(separator: "\r\n") {
            if let colon = line.firstIndex(of: ":"), line[line.startIndex..<colon].uppercased().trimmingCharacters(in: .whitespaces) == "LOCATION" {
                return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func finishListening(then: @escaping (Set<URL>) -> Void) {
        readSource?.cancel()
        readSource = nil
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        then(discoveredLocations)
    }

    private func resolveDevices(locations: Set<URL>, completion: @escaping ([SonosDevice]) -> Void) {
        guard !locations.isEmpty else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        var devices: [SonosDevice] = []
        let group = DispatchGroup()
        for location in locations {
            group.enter()
            fetchDeviceDescription(location: location) { device in
                if let device { devices.append(device) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            var seen = Set<String>()
            let deduped = devices.filter { seen.insert($0.udn).inserted }
            completion(deduped)
        }
    }

    private func fetchDeviceDescription(location: URL, completion: @escaping (SonosDevice?) -> Void) {
        URLSession.shared.dataTask(with: location) { data, _, error in
            guard let data, error == nil else {
                completion(nil)
                return
            }
            let parser = DeviceDescriptionParser()
            guard parser.parse(data: data), parser.deviceType.contains("ZonePlayer"),
                  !parser.roomName.isEmpty, !parser.udn.isEmpty else {
                completion(nil)
                return
            }
            completion(SonosDevice(udn: parser.udn, roomName: parser.roomName, ipAddress: location.host ?? ""))
        }.resume()
    }
}

final class DeviceDescriptionParser: NSObject, XMLParserDelegate {
    private(set) var roomName = ""
    private(set) var udn = ""
    private(set) var deviceType = ""
    private var currentElement = ""

    func parse(data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch currentElement {
        case "roomName": roomName += string
        case "UDN": udn += string
        case "deviceType": deviceType += string
        default: break
        }
    }
}
