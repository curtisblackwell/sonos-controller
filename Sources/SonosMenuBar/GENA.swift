import Foundation
import os.log

/// UPnP eventing (GENA) subscription verbs. They are plain HTTP requests with unusual
/// methods against a service's event URL, and URLSession forwards a method it doesn't know
/// as-is, so there is no socket work here.
enum GENA {
    private static let log = Logger(subsystem: "com.curtis.sonos-controller", category: "gena")

    /// How long to ask a speaker to hold the subscription for.
    ///
    /// Renewal is the only thing that ever notices a subscription has died - a speaker that
    /// rebooted and forgot us sends nothing, and silence is indistinguishable from a
    /// household where nobody has touched anything. So the lease doubles as the liveness
    /// probe, and a short one is the difference between noticing in minutes and noticing in
    /// a quarter of an hour. One small request every couple of minutes is a fair price.
    ///
    /// Sonos answers with what it actually granted, which is what we renew against.
    static let requestedTimeout = 300

    /// A live subscription: the speaker's handle for it, and how long it lasts unrenewed.
    struct Lease {
        let sid: String
        let timeout: TimeInterval
    }

    enum Failure: LocalizedError {
        case badURL
        case transport(Error)
        case httpStatus(Int)
        case missingSID

        var errorDescription: String? {
            switch self {
            case .badURL: return "Malformed event URL"
            case let .transport(error): return error.localizedDescription
            case let .httpStatus(code): return "HTTP \(code)"
            case .missingSID: return "Response had no SID header"
            }
        }
    }

    /// Opens a new subscription. `callbackURL` must be an address the speaker can reach us
    /// at - it opens a fresh connection to it for every event.
    static func subscribe(eventURL: URL, callbackURL: URL, completion: @escaping (Result<Lease, Failure>) -> Void) {
        var request = URLRequest(url: eventURL)
        request.httpMethod = "SUBSCRIBE"
        request.setValue("<\(callbackURL.absoluteString)>", forHTTPHeaderField: "CALLBACK")
        request.setValue("upnp:event", forHTTPHeaderField: "NT")
        request.setValue("Second-\(requestedTimeout)", forHTTPHeaderField: "TIMEOUT")
        send(request, completion: completion)
    }

    /// Extends an existing subscription. Deliberately carries no CALLBACK or NT header:
    /// sending either alongside SID is how you get a 400 back.
    static func renew(eventURL: URL, sid: String, completion: @escaping (Result<Lease, Failure>) -> Void) {
        var request = URLRequest(url: eventURL)
        request.httpMethod = "SUBSCRIBE"
        request.setValue(sid, forHTTPHeaderField: "SID")
        request.setValue("Second-\(requestedTimeout)", forHTTPHeaderField: "TIMEOUT")
        send(request, completion: completion)
    }

    /// Best effort - a subscription we walk away from expires on its own within the lease,
    /// so there is nothing useful to do about a failure here.
    static func unsubscribe(eventURL: URL, sid: String) {
        var request = URLRequest(url: eventURL)
        request.httpMethod = "UNSUBSCRIBE"
        request.setValue(sid, forHTTPHeaderField: "SID")
        URLSession.shared.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            log.notice("UNSUBSCRIBE \(sid, privacy: .public) -> \(status, privacy: .public) \(error?.localizedDescription ?? "", privacy: .public)")
        }.resume()
    }

    private static func send(_ request: URLRequest, completion: @escaping (Result<Lease, Failure>) -> Void) {
        URLSession.shared.dataTask(with: request) { _, response, error in
            let result: Result<Lease, Failure>
            if let error {
                result = .failure(.transport(error))
            } else if let http = response as? HTTPURLResponse {
                if (200..<300).contains(http.statusCode) {
                    if let sid = http.value(forHTTPHeaderField: "SID"), !sid.isEmpty {
                        let timeout = parseTimeout(http.value(forHTTPHeaderField: "TIMEOUT"))
                        result = .success(Lease(sid: sid, timeout: timeout))
                    } else {
                        result = .failure(.missingSID)
                    }
                } else {
                    result = .failure(.httpStatus(http.statusCode))
                }
            } else {
                result = .failure(.httpStatus(0))
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    /// `Second-1800`, or `infinite` for a lease with no expiry. An unparseable header falls
    /// back to what we asked for: renewing sooner than needed is free, renewing too late
    /// loses events silently.
    static func parseTimeout(_ header: String?) -> TimeInterval {
        guard let header = header?.trimmingCharacters(in: .whitespaces) else { return TimeInterval(requestedTimeout) }
        if header.caseInsensitiveCompare("infinite") == .orderedSame { return TimeInterval(requestedTimeout) }
        guard header.lowercased().hasPrefix("second-"),
              let seconds = TimeInterval(header.dropFirst("second-".count)),
              seconds > 0
        else { return TimeInterval(requestedTimeout) }
        return seconds
    }
}
