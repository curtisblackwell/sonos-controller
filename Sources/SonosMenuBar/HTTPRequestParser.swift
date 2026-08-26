import Foundation

/// Just enough HTTP/1.1 to read a UPnP event callback off a socket: a request line, headers,
/// and a Content-Length body. Nothing here is a general-purpose server - no chunked bodies,
/// no keep-alive, no pipelining - because the only thing that ever talks to it is a speaker
/// sending a single NOTIFY per connection.
struct HTTPRequestParser {
    struct Request {
        let method: String
        let path: String
        /// Names lowercased: HTTP header names are case-insensitive and speakers are not
        /// consistent about which case they send (`SID` vs `Sid`).
        let headers: [String: String]
        let body: Data
    }

    private var buffer = Data()
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    /// Feeds another chunk from the socket. Returns the request once the headers and the
    /// whole declared body have arrived, and nil while it is still incomplete - a body of
    /// any size arrives in several reads.
    mutating func consume(_ chunk: Data) -> Request? {
        buffer.append(chunk)

        guard let terminator = buffer.firstRange(of: Self.headerTerminator),
              let headerText = String(data: buffer[buffer.startIndex..<terminator.lowerBound], encoding: .utf8)
        else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ", omittingEmptySubsequences: true) ?? []
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let contentLength = headers["content-length"].flatMap { Int($0) } ?? 0
        let bodyStart = terminator.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= contentLength else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)

        return Request(
            method: requestLine[0].uppercased(),
            path: String(requestLine[1]),
            headers: headers,
            body: Data(buffer[bodyStart..<bodyEnd])
        )
    }
}
