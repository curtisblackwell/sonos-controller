import Foundation
import Testing
@testable import SonosMenuBar

struct XMLEscapingTests {
    @Test func unescapedIsTheInverseOfEscaped() {
        let original = "Rock & Roll <Live> \"Encore\" 'Side B'"
        #expect(SonosSOAP.xmlUnescaped(SonosSOAP.xmlEscaped(original)) == original)
    }

    /// `&amp;` has to unescape last, or `&amp;lt;` (an escaped ampersand followed by literal
    /// text) would be read back as `<` instead of `&lt;`.
    @Test func ampersandDoesNotSwallowOtherEntities() {
        #expect(SonosSOAP.xmlUnescaped("&amp;lt;") == "&lt;")
    }
}

struct TimeParsingTests {
    @Test func parsesHoursMinutesSeconds() {
        let body = Data("<RelTime>0:03:07</RelTime>".utf8)
        #expect(SonosSOAP.timeSeconds(named: "RelTime", in: body) == 187)
    }

    @Test func parsesPastAnHour() {
        let body = Data("<TrackDuration>1:02:03</TrackDuration>".utf8)
        #expect(SonosSOAP.timeSeconds(named: "TrackDuration", in: body) == 3723)
    }

    @Test func missingFieldReadsAsNothing() {
        #expect(SonosSOAP.timeSeconds(named: "RelTime", in: Data()) == nil)
    }

    @Test func formatTimeIsTheInverseOfTimeSeconds() {
        #expect(SonosSOAP.formatTime(seconds: 187) == "0:03:07")
        #expect(SonosSOAP.formatTime(seconds: 3723) == "1:02:03")
        #expect(SonosSOAP.formatTime(seconds: -5) == "0:00:00")
    }
}

struct TrackMetadataTests {
    private func positionInfo(trackMetaData: String, duration: String = "0:03:30", relTime: String = "0:01:00") -> Data {
        Data("""
        <TrackDuration>\(duration)</TrackDuration>
        <RelTime>\(relTime)</RelTime>
        <TrackMetaData>\(trackMetaData)</TrackMetaData>
        """.utf8)
    }

    @Test func parsesTitleArtistAlbumAndResolvesRelativeArt() {
        let didl = SonosSOAP.xmlEscaped("""
        <DIDL-Lite><item><dc:title>Song</dc:title><dc:creator>Artist</dc:creator>\
        <upnp:album>Album</upnp:album><upnp:albumArtURI>/getaa?u=x&amp;v=1</upnp:albumArtURI></item></DIDL-Lite>
        """)
        let track = SonosControl.trackMetadata(from: positionInfo(trackMetaData: didl), coordinatorIP: "192.168.1.50")
        #expect(track?.title == "Song")
        #expect(track?.artist == "Artist")
        #expect(track?.album == "Album")
        #expect(track?.albumArtURL?.absoluteString == "http://192.168.1.50:1400/getaa?u=x&v=1")
    }

    @Test func absoluteArtURIIsUsedAsIs() {
        let didl = SonosSOAP.xmlEscaped(
            "<DIDL-Lite><item><dc:title>Song</dc:title><upnp:albumArtURI>http://cdn.example/art.jpg</upnp:albumArtURI></item></DIDL-Lite>"
        )
        let track = SonosControl.trackMetadata(from: positionInfo(trackMetaData: didl), coordinatorIP: "192.168.1.50")
        #expect(track?.albumArtURL?.absoluteString == "http://cdn.example/art.jpg")
    }

    /// Sent literally, not as XML, when nothing is playing - a value most parsers would choke
    /// trying to unescape as DIDL-Lite.
    @Test func notImplementedReadsAsNoTrack() {
        #expect(SonosControl.trackMetadata(from: positionInfo(trackMetaData: "NOT_IMPLEMENTED"), coordinatorIP: "192.168.1.50") == nil)
    }

    @Test func durationParsesFromTheSameResponse() {
        let data = positionInfo(trackMetaData: "NOT_IMPLEMENTED", duration: "0:04:12")
        #expect(SonosControl.trackDurationSeconds(from: data) == 252)
    }
}
