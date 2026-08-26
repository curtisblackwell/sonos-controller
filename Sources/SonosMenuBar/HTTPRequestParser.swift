import Foundation

/// Just enough HTTP/1.1 to read a UPnP event callback off a socket: a request line, headers,
/// and a Content-Length body. Nothing here is a general-purpose server - no chunked bodies,
/// no keep-alive, no pipelining - because the only thing that ever talks to it is a speaker
/// sending a single NOTIFY per connection.
///
/// It is, however, reachable by anything on the LAN, so a request it can't make sense of has
/// to end the connection rather than be waited on forever.
struct HTTPRequestParser {
    struct Request {
        let method: String
        let path: String
        /// Names lowercased: HTTP header names are case-insensitive and speakers are not
        /// consistent about which case they send (`SID` vs `Sid`).
        let headers: [String: String]
        let body: Data
    }

    enum Outcome {
        /// More bytes needed; keep reading.
        case incomplete
        case complete(Request)
        /// Unparseable or oversized. The caller must close the connection - there is no
        /// resynchronising a stream we've lost our place in.
        case malformed
    }

    /// A topology event for a large household is tens of KB; a megabyte is far past anything
    /// legitimate and stops a peer that never stops sending from growing `buffer` unbounded.
    static let maxRequestBytes = 1024 * 1024

    private var buffer = Data()
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    /// Feeds another chunk from the socket. Reports `.complete` once the headers and the
    /// whole declared body have arrived - a body of any size takes several reads to get.
    mutating func consume(_ chunk: Data) -> Outcome {
        buffer.append(chunk)
        guard buffer.count <= Self.maxRequestBytes else { return .malformed }

        guard let terminator = buffer.firstRange(of: Self.headerTerminator) else { return .incomplete }
        guard let headerText = String(data: buffer[buffer.startIndex..<terminator.lowerBound], encoding: .utf8)
        else { return .malformed }

        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ", omittingEmptySubsequences: true) ?? []
        guard requestLine.count >= 2 else { return .malformed }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        // A negative or absurd length is hostile, not a slow sender: taking it at face value
        // and slicing with it traps.
        let declaredLength = headers["content-length"].flatMap { Int($0) } ?? 0
        guard declaredLength >= 0, declaredLength <= Self.maxRequestBytes else { return .malformed }

        let bodyStart = terminator.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= declaredLength else { return .incomplete }
        let bodyEnd = buffer.index(bodyStart, offsetBy: declaredLength)

        return .complete(Request(
            method: requestLine[0].uppercased(),
            path: String(requestLine[1]),
            headers: headers,
            body: Data(buffer[bodyStart..<bodyEnd])
        ))
    }
}
