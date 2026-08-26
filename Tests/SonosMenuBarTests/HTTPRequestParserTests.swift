import Testing
import Foundation
@testable import SonosMenuBar

struct HTTPRequestParserTests {
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
        let request = parser.consume(Data(notify(body: "<propertyset/>").utf8))
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
        #expect(parser.consume(Data(raw[0..<split])) == nil)
        let request = parser.consume(Data(raw[split...]))
        #expect(request.map { String(decoding: $0.body, as: UTF8.self) } == "<propertyset>lots of state</propertyset>")
    }

    @Test func waitsForTheHeadersToFinish() {
        // The split lands mid-header, so there is no terminator to find yet.
        let raw = Array(notify(body: "<propertyset/>").utf8)
        var parser = HTTPRequestParser()
        #expect(parser.consume(Data(raw[0..<20])) == nil)
        #expect(parser.consume(Data(raw[20...])) != nil)
    }

    @Test func headerNamesAreCaseInsensitive() {
        // Speakers are inconsistent about this; SID and Sid are the same header.
        var parser = HTTPRequestParser()
        let request = parser.consume(Data(notify(body: "x", extraHeaders: "Nt: upnp:event\r\n").utf8))
        #expect(request?.headers["nt"] == "upnp:event")
        #expect(request?.headers["content-type"] == "text/xml")
    }

    @Test func aRequestWithNoContentLengthHasNoBody() {
        var parser = HTTPRequestParser()
        let request = parser.consume(Data("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
        #expect(request?.method == "GET")
        #expect(request?.body.isEmpty == true)
    }

    @Test func bodyStopsAtContentLength() {
        // Anything after the declared length belongs to a following request, not this one.
        var parser = HTTPRequestParser()
        let raw = "NOTIFY /notify HTTP/1.1\r\nContent-Length: 4\r\n\r\nbodyTRAILING"
        let request = parser.consume(Data(raw.utf8))
        #expect(request.map { String(decoding: $0.body, as: UTF8.self) } == "body")
    }
}
