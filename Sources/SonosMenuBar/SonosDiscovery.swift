import Foundation
import os.log

final class SonosDiscovery: NSObject {
    private static let log = Logger(subsystem: "com.curtisblackwell.sonos-controller", category: "discovery")
    private static let ssdpAddress = "239.255.255.250"
    private static let ssdpPort: UInt16 = 1900
    private static let searchTarget = "urn:schemas-upnp-org:device:ZonePlayer:1"

    /// All mutable discovery state lives on this queue - including the read source's event
    /// handler - so a rescan tapped mid-scan can't race with the in-flight socket teardown.
    private let queue = DispatchQueue(label: "com.curtisblackwell.sonos-controller.discovery")
    private var readSource: DispatchSourceRead?
    private var discoveredLocations: Set<URL> = []
    private var isDiscovering = false
    private var pendingCompletions: [([SonosDevice]) -> Void] = []

    /// Runs an SSDP search for ~3s, resolves each responding device's description XML,
    /// then calls completion once on the main thread with the deduped device list.
    /// A call made while a scan is already running joins that scan rather than starting
    /// a second one - two overlapping scans would tear down each other's socket.
    func discover(completion: @escaping ([SonosDevice]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingCompletions.append(completion)
            guard !self.isDiscovering else {
                Self.log.notice("Discovery already in progress, joining it")
                return
            }
            self.isDiscovering = true
            self.discoveredLocations = []
            self.startScan()
        }
    }

    /// Must be called on `queue`.
    private func startScan() {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            Self.log.error("Failed to create SSDP socket")
            finish(with: [])
            return
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readAvailableData(fd: fd)
        }
        // Closing the fd is the cancel handler's job: cancellation is asynchronous, so
        // closing it alongside cancel() can let the event handler recv() on a closed -
        // and possibly already reused - descriptor.
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        readSource = source

        sendSearch(fd: fd)
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.readSource != nil else { return }
            self.sendSearch(fd: fd)
        }
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.readSource != nil else { return }
            self.sendSearch(fd: fd)
        }

        queue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, self.readSource != nil else { return }
            self.readSource?.cancel()
            self.readSource = nil
            self.resolveDevices(locations: self.discoveredLocations)
        }
    }

    /// IPv4 addresses of every up, multicast-capable, non-loopback interface. An unbound
    /// socket sends multicast out whichever single interface the routing table picks, which
    /// with a VPN or a second wired/wireless link is often not the one the speakers are on -
    /// so we set IP_MULTICAST_IF and send the M-SEARCH out each candidate in turn.
    static func multicastInterfaceAddresses() -> [in_addr] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, head != nil else { return [] }
        defer { freeifaddrs(head) }

        var addresses: [in_addr] = []
        var seen = Set<UInt32>()
        var cursor = head
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0,
                  flags & IFF_MULTICAST != 0,
                  let sockAddr = current.pointee.ifa_addr,
                  sockAddr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let addr = sockAddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            if seen.insert(addr.s_addr).inserted {
                addresses.append(addr)
            }
        }
        return addresses
    }

    private func sendSearch(fd: Int32) {
        let message = "M-SEARCH * HTTP/1.1\r\n" +
            "HOST: \(Self.ssdpAddress):\(Self.ssdpPort)\r\n" +
            "MAN: \"ssdp:discover\"\r\n" +
            "MX: 2\r\n" +
            "ST: \(Self.searchTarget)\r\n" +
            "\r\n"
        guard let data = message.data(using: .utf8) else { return }

        let interfaces = Self.multicastInterfaceAddresses()
        if interfaces.isEmpty {
            Self.log.notice("No multicast-capable IPv4 interfaces found, sending on default route")
            sendDatagram(data, fd: fd)
            return
        }
        for var interface in interfaces {
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &interface, socklen_t(MemoryLayout<in_addr>.size))
            sendDatagram(data, fd: fd)
        }
    }

    private func sendDatagram(_ data: Data, fd: Int32) {
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

    private func readAvailableData(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = recv(fd, &buffer, buffer.count, 0)
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

    /// Must be called on `queue`. Hands the result to every caller waiting on this scan.
    private func finish(with devices: [SonosDevice]) {
        readSource?.cancel()
        readSource = nil
        isDiscovering = false
        let completions = pendingCompletions
        pendingCompletions = []
        DispatchQueue.main.async {
            for completion in completions { completion(devices) }
        }
    }

    private func resolveDevices(locations: Set<URL>) {
        guard !locations.isEmpty else {
            finish(with: [])
            return
        }
        // Description fetches complete on arbitrary URLSession queues, so collect onto
        // `queue` rather than appending to a shared array from all of them at once.
        var devices: [SonosDevice] = []
        let group = DispatchGroup()
        for location in locations {
            group.enter()
            fetchDeviceDescription(location: location) { [weak self] device in
                guard let self else { group.leave(); return }
                self.queue.async {
                    if let device { devices.append(device) }
                    group.leave()
                }
            }
        }
        group.notify(queue: queue) { [weak self] in
            var seen = Set<String>()
            let deduped = devices.filter { seen.insert($0.udn).inserted }
            self?.finish(with: deduped)
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

    // Without this, currentElement stays set after the element closes and the whitespace
    // between siblings gets appended to whichever field we captured last.
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if currentElement == elementName { currentElement = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch currentElement {
        case "roomName": roomName += string
        case "UDN": udn += string
        case "deviceType": deviceType += string
        default: break
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        roomName = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        udn = udn.trimmingCharacters(in: .whitespacesAndNewlines)
        deviceType = deviceType.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
