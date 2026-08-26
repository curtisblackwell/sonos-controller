import Foundation
import Network
import os.log

/// The HTTP server half of a UPnP event subscription. Speakers deliver events by sending a
/// NOTIFY to a callback URL, so subscribing means being reachable - there is no way to have
/// them pushed down the subscribing connection.
///
/// It serves exactly one path and answers everything else with a 404. Anything on the LAN can
/// connect to it, so it reports who sent each event and lets the caller decide whether to
/// believe it.
final class GENAEventListener {
    private static let log = Logger(subsystem: "com.curtis.sonos-controller", category: "gena-listener")
    static let callbackPath = "/notify"

    /// A speaker that has opened a connection but not finished a request by then is either
    /// broken or not a speaker; either way the socket is not worth holding open.
    private static let requestTimeout: TimeInterval = 15

    /// Called on the main thread with the NOTIFY's SID header (empty if it had none), the
    /// address it came from, and the body.
    var onEvent: ((_ sid: String, _ sourceIP: String, _ body: Data) -> Void)?

    /// Called on the main thread if the listener dies after having been ready. Every
    /// subscription pointing at its port is now undeliverable, so the owner has to stand a
    /// new one up and subscribe again.
    var onFailure: (() -> Void)?

    /// Main thread only, so `callbackURL(reachableFrom:)` can be called straight from the
    /// subscribe path without hopping queues.
    private(set) var port: UInt16?

    private let queue = DispatchQueue(label: "com.curtis.sonos-controller.gena-listener")
    private var listener: NWListener?
    /// One per open connection. NWConnection isn't retained by the listener, so dropping an
    /// entry here is what tears the connection down.
    private var connections: [ObjectIdentifier: ConnectionState] = [:]

    /// The per-connection state a receive loop needs. A class so the loop can be a method -
    /// as a local function recursing into its own escaping closure it captured itself, and
    /// leaked the connection and its buffer on every event.
    private final class ConnectionState {
        let connection: NWConnection
        var parser = HTTPRequestParser()
        var timeout: DispatchWorkItem?

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

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
                let hadBeenReady = didComplete
                finish(nil)
                DispatchQueue.main.async { [weak self] in
                    // A failed NWListener can't be restarted, and leaving it in `listener`
                    // makes every later `start` short-circuit on the corpse and report nil
                    // forever. Identity check so a listener stood up since then survives.
                    guard let self, self.listener === listener else { return }
                    self.listener?.cancel()
                    self.listener = nil
                    self.port = nil
                    // Only meaningful once it had been ready: before that, `start`'s own
                    // completion is what tells the caller it didn't work.
                    if hadBeenReady { self.onFailure?() }
                }
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
            for state in self.connections.values {
                state.timeout?.cancel()
                state.connection.cancel()
            }
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

    /// The peer's address, with the noise an NWEndpoint description carries stripped: a
    /// scope id on link-local addresses, and the `::ffff:` prefix a dual-stack listener puts
    /// in front of IPv4 peers. Callers compare this against a speaker's address, so the two
    /// have to be spelled the same way.
    static func sourceIP(of endpoint: NWEndpoint) -> String {
        guard case let .hostPort(host, _) = endpoint else { return "" }
        var text = "\(host)"
        if let percent = text.firstIndex(of: "%") { text = String(text[text.startIndex..<percent]) }
        if text.hasPrefix("::ffff:") { text = String(text.dropFirst("::ffff:".count)) }
        return text
    }

    // MARK: - Connection handling

    /// Runs on `queue`, as does everything it starts.
    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        let state = ConnectionState(connection: connection)
        connections[key] = state

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.connections[key] != nil else { return }
            Self.log.notice("Dropping a connection that never finished its request")
            self.closeConnection(key)
        }
        state.timeout = timeout
        queue.asyncAfter(deadline: .now() + Self.requestTimeout, execute: timeout)

        connection.stateUpdateHandler = { [weak self] connectionState in
            switch connectionState {
            case .failed, .cancelled:
                self?.closeConnection(key)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(key)
    }

    private func receive(_ key: ObjectIdentifier) {
        guard let state = connections[key] else { return }
        state.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, let state = self.connections[key] else { return }
            if let data, !data.isEmpty {
                switch state.parser.consume(data) {
                case let .complete(request):
                    // No close here: `respond` hangs it off the send, so the speaker
                    // actually gets its 200.
                    self.respond(to: request, on: state.connection, key: key)
                    return
                case .malformed:
                    self.closeConnection(key)
                    return
                case .incomplete:
                    break
                }
            }
            // A body split across reads is the normal case; only give up when the peer is
            // finished or the socket broke.
            guard !isComplete, error == nil else {
                self.closeConnection(key)
                return
            }
            self.receive(key)
        }
    }

    /// Must be called on `queue`. Cancelling re-enters through `stateUpdateHandler`, which
    /// is harmless once the entry is gone.
    private func closeConnection(_ key: ObjectIdentifier) {
        guard let state = connections.removeValue(forKey: key) else { return }
        state.timeout?.cancel()
        state.connection.cancel()
    }

    private func respond(to request: HTTPRequestParser.Request, on connection: NWConnection, key: ObjectIdentifier) {
        let isEvent = request.method == "NOTIFY" && request.path == Self.callbackPath
        let status = isEvent ? "200 OK" : "404 Not Found"
        // Answer before doing anything with the body: a speaker that doesn't get its 200
        // quickly drops the subscription.
        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            self?.closeConnection(key)
        })

        guard isEvent else { return }
        let sid = request.headers["sid"] ?? ""
        let sourceIP = Self.sourceIP(of: connection.endpoint)
        let body = request.body
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(sid, sourceIP, body)
        }
    }
}
