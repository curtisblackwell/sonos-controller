import Foundation
import Network
import os.log

/// The HTTP server half of a UPnP event subscription. Speakers deliver events by sending a
/// NOTIFY to a callback URL, so subscribing means being reachable - there is no way to have
/// them pushed down the subscribing connection.
///
/// It serves exactly one path and answers everything else with a 404.
final class GENAEventListener {
    private static let log = Logger(subsystem: "com.curtis.sonos-controller", category: "gena-listener")
    static let callbackPath = "/notify"

    /// Called on the main thread with the NOTIFY's SID header (empty if it had none) and body.
    var onEvent: ((String, Data) -> Void)?

    /// Main thread only, so `callbackURL(reachableFrom:)` can be called straight from the
    /// subscribe path without hopping queues.
    private(set) var port: UInt16?

    private let queue = DispatchQueue(label: "com.curtis.sonos-controller.gena-listener")
    private var listener: NWListener?
    /// NWConnection is not retained by the listener, so a connection dropped here is a
    /// connection torn down mid-request.
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// Binds an ephemeral port and calls back on the main thread with it, or nil if the
    /// listener could not start - in which case there is no point subscribing to anything.
    func start(completion: @escaping (UInt16?) -> Void) {
        guard listener == nil else {
            completion(port)
            return
        }
        let parameters = NWParameters.tcp
        // A listener left over from a crashed run can hold the port briefly.
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: .any)
        } catch {
            Self.log.error("Couldn't create event listener: \(error.localizedDescription, privacy: .public)")
            completion(nil)
            return
        }
        self.listener = listener

        var didComplete = false
        let finish: (UInt16?) -> Void = { boundPort in
            guard !didComplete else { return }
            didComplete = true
            DispatchQueue.main.async {
                self.port = boundPort
                completion(boundPort)
            }
        }

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let boundPort = self?.listener?.port?.rawValue
                Self.log.notice("Event listener ready on port \(boundPort ?? 0, privacy: .public)")
                finish(boundPort)
            case let .failed(error):
                Self.log.error("Event listener failed: \(error.localizedDescription, privacy: .public)")
                finish(nil)
            case .cancelled:
                finish(nil)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        port = nil
        listener?.cancel()
        listener = nil
        queue.async {
            for connection in self.connections.values { connection.cancel() }
            self.connections = [:]
        }
    }

    /// The callback URL to hand a speaker at `ip`. The host has to be our address on the
    /// interface that reaches *that* speaker: with a VPN or a second link up this machine
    /// has several, and a callback URL naming the wrong one is never delivered to.
    func callbackURL(reachableFrom ip: String) -> URL? {
        guard let port, let localIP = Self.localAddress(reaching: ip) else { return nil }
        return URL(string: "http://\(localIP):\(port)\(Self.callbackPath)")
    }

    /// Which of this machine's addresses the kernel would use to talk to `host`. Connecting
    /// a UDP socket sends no packets - it only fixes the route - so this is a lookup, not a
    /// probe, and it costs nothing when the host is unreachable.
    static func localAddress(reaching host: String) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var remote = sockaddr_in()
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = UInt16(1400).bigEndian
        guard inet_pton(AF_INET, host, &remote.sin_addr) == 1 else { return nil }

        let connected = withUnsafePointer(to: &remote) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { return nil }

        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &local.sin_addr, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: text)
    }

    // MARK: - Connection handling

    /// Runs on `queue`, as does everything it starts: `connections` is touched from the
    /// receive completions too.
    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection

        var parser = HTTPRequestParser()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections[key] = nil
            default:
                break
            }
        }

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty, let request = parser.consume(data) {
                    self.respond(to: request, on: connection)
                    return
                }
                // A body split across reads is the normal case; only give up when the peer
                // is finished or the socket broke.
                guard !isComplete, error == nil else {
                    connection.cancel()
                    return
                }
                receive()
            }
        }

        connection.start(queue: queue)
        receive()
    }

    private func respond(to request: HTTPRequestParser.Request, on connection: NWConnection) {
        let isEvent = request.method == "NOTIFY" && request.path == Self.callbackPath
        let status = isEvent ? "200 OK" : "404 Not Found"
        // Answer before doing anything with the body: a speaker that doesn't get its 200
        // quickly drops the subscription.
        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })

        guard isEvent else { return }
        let sid = request.headers["sid"] ?? ""
        let body = request.body
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(sid, body)
        }
    }
}
