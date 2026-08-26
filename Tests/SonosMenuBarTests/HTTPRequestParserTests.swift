import Testing
import Foundation
@testable import SonosMenuBar

struct HTTPRequestParserTests {
    /// The tests care about the request or the absence of one; `.malformed` has its own
    /// checks below.
    private func request(_ outcome: HTTPRequestParser.Outcome) -> HTTPRequestParser.Request? {
        guard case let .complete(request) = outcome else { return nil }
        return request
    }

    private func isMalformed(_ outcome: HTTPRequestParser.Outcome) -> Bool {
        if case .malformed = outcome { return true }
        return false
    }

    private func isIncomplete(_ outcome: HTTPRequestParser.Outcome) -> Bool {
        if case .incomplete = outcome { return true }
        return false
    }

    private func notify(body: String, extraHeaders: String = "") -> String {
        "NOTIFY /notify HTTP/1.1\r\n" +
            "HOST: 192.168.1.10:52341\r\n" +
            "CONTENT-TYPE: text/xml\r\n" +
            "SID: uuid:RINCON-abc\r\n" +
            "Content-Length: \(body.utf8.count)\r\n" +
            extraHeaders +
            "\r\n" +
            body
    }

    @Test func parsesACompleteRequestInOneChunk() {
        var parser = HTTPRequestParser()
        let request = request(parser.consume(Data(notify(body: "<propertyset/>").utf8)))
        #expect(request?.method == "NOTIFY")
        #expect(request?.path == "/notify")
        #expect(request?.headers["sid"] == "uuid:RINCON-abc")
        #expect(request.map { String(decoding: $0.body, as: UTF8.self) } == "<propertyset/>")
    }

    @Test func waitsForTheWholeBody() {
        // A topology event runs to several KB and never arrives in a single read.
        let raw = Array(notify(body: "<propertyset>lots of state</propertyset>").utf8)
        var parser = HTTPRequestParser()
        let split = raw.count - 12
        #expect(isIncomplete(parser.consume(Data(raw[0..<split]))))
        let request = request(parser.consume(Data(raw[split...])))
        #expect(request.map { String(decoding: $0.body, as: UTF8.self) } == "<propertyset>lots of state</propertyset>")
    }

    @Test func waitsForTheHeadersToFinish() {
        // The split lands mid-header, so there is no terminator to find yet.
        let raw = Array(notify(body: "<propertyset/>").utf8)
        var parser = HTTPRequestParser()
        #expect(isIncomplete(parser.consume(Data(raw[0..<20]))))
        #expect(request(parser.consume(Data(raw[20...]))) != nil)
    }

    @Test func headerNamesAreCaseInsensitive() {
        // Speakers are inconsistent about this; SID and Sid are the same header.
        var parser = HTTPRequestParser()
        let request = request(parser.consume(Data(notify(body: "x", extraHeaders: "Nt: upnp:event\r\n").utf8)))
        #expect(request?.headers["nt"] == "upnp:event")
        #expect(request?.headers["content-type"] == "text/xml")
    }

    @Test func aRequestWithNoContentLengthHasNoBody() {
        var parser = HTTPRequestParser()
        let request = request(parser.consume(Data("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8)))
        #expect(request?.method == "GET")
        #expect(request?.body.isEmpty == true)
    }

    @Test func bodyStopsAtContentLength() {
        // Anything after the declared length belongs to a following request, not this one.
        var parser = HTTPRequestParser()
        let raw = "NOTIFY /notify HTTP/1.1\r\nContent-Length: 4\r\n\r\nbodyTRAILING"
        let request = request(parser.consume(Data(raw.utf8)))
        #expect(request.map { String(decoding: $0.body, as: UTF8.self) } == "body")
    }

    @Test func aNegativeContentLengthIsMalformed() {
        // Taking it at face value slices with lowerBound > upperBound, which traps - and
        // anything on the LAN can send it.
        var parser = HTTPRequestParser()
        let raw = "NOTIFY /notify HTTP/1.1\r\nContent-Length: -5\r\n\r\nbody"
        #expect(isMalformed(parser.consume(Data(raw.utf8))))
    }

    @Test func anAbsurdContentLengthIsMalformed() {
        var parser = HTTPRequestParser()
        let raw = "NOTIFY /notify HTTP/1.1\r\nContent-Length: 99999999999\r\n\r\n"
        #expect(isMalformed(parser.consume(Data(raw.utf8))))
    }

    @Test func aRequestLineThatIsNotOneIsMalformed() {
        var parser = HTTPRequestParser()
        #expect(isMalformed(parser.consume(Data("garbage\r\n\r\n".utf8))))
    }

    @Test func anEndlessRequestIsCutOffRatherThanBuffered() {
        // No terminator ever arrives, so nothing here is parseable; the cap is the only
        // thing that stops the buffer growing for as long as the peer keeps typing.
        var parser = HTTPRequestParser()
        let chunk = Data(repeating: UInt8(ascii: "a"), count: 256 * 1024)
        var outcome = HTTPRequestParser.Outcome.incomplete
        for _ in 0..<8 { outcome = parser.consume(chunk) }
        #expect(isMalformed(outcome))
    }
}
