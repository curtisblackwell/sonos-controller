import Testing
import Foundation
@testable import SonosMenuBar

/// Fixtures are real responses captured from a live household (firmware 86.8) rather than
/// hand-written XML, so the parser is tested against the shapes Sonos actually sends -
/// including the double-escaped `r:resMD` and the mix of services in one favorites list.
private enum Fixture {
    /// Two favorites: a YouTube Music playlist and a Spotify album. Note `&amp;amp;` in the
    /// first title, the `r:resMD` nested DIDL-Lite, and the `<desc id="cdudn">` credential
    /// token inside it.
    static let favorites = """
    <?xml version="1.0"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
    <s:Body><u:BrowseResponse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
    <Result>&lt;DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"&gt;&lt;item id="FV:2/18" parentID="FV:2" restricted="false"&gt;&lt;dc:title&gt;Acoustic Indie &amp;amp; Alternative&lt;/dc:title&gt;&lt;upnp:class&gt;object.itemobject.item.sonos-favorite&lt;/upnp:class&gt;&lt;res protocolInfo="x-rincon-cpcontainer:*:*:*"&gt;x-rincon-cpcontainer:1006004cALkSOiESaEoG?sid=284&amp;amp;flags=76&amp;amp;sn=3&lt;/res&gt;&lt;upnp:albumArtURI&gt;https://lh3.googleusercontent.com/9T5Gi&lt;/upnp:albumArtURI&gt;&lt;r:description&gt;YouTube Music&lt;/r:description&gt;&lt;r:resMD&gt;&amp;lt;DIDL-Lite&amp;gt;&amp;lt;item id=&amp;quot;1006004cALkSOiESaEoG&amp;quot; restricted=&amp;quot;true&amp;quot;&amp;gt;&amp;lt;dc:title&amp;gt;Acoustic Indie &amp;amp;amp; Alternative&amp;lt;/dc:title&amp;gt;&amp;lt;upnp:class&amp;gt;object.container.playlistContainer&amp;lt;/upnp:class&amp;gt;&amp;lt;desc id=&amp;quot;cdudn&amp;quot; nameSpace=&amp;quot;urn:schemas-rinconnetworks-com:metadata-1-0/&amp;quot;&amp;gt;SA_RINCON72711_X_#Svc72711-0-Token&amp;lt;/desc&amp;gt;&amp;lt;/item&amp;gt;&amp;lt;/DIDL-Lite&amp;gt;&lt;/r:resMD&gt;&lt;/item&gt;&lt;item id="FV:2/30" parentID="FV:2" restricted="false"&gt;&lt;dc:title&gt;Classics&lt;/dc:title&gt;&lt;upnp:class&gt;object.container.album.musicAlbum&lt;/upnp:class&gt;&lt;res protocolInfo="x-rincon-cpcontainer:*:*:*"&gt;x-rincon-cpcontainer:00040000spotify%3aalbum%3a7cKqnavORKemYZ41wFtx5J?sid=12&amp;amp;flags=4&amp;amp;sn=13&lt;/res&gt;&lt;r:description&gt;Album by Ratatat&lt;/r:description&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</Result>
    <NumberReturned>2</NumberReturned><TotalMatches>2</TotalMatches><UpdateID>1</UpdateID>
    </u:BrowseResponse></s:Body></s:Envelope>
    """

    /// One queue track, with the relative `/getaa?...` album art path and a Spotify track URI.
    static let queue = """
    <?xml version="1.0"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
    <s:Body><u:BrowseResponse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
    <Result>&lt;DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"&gt;&lt;item id="Q:0/1" parentID="Q:0" restricted="true"&gt;&lt;res protocolInfo="sonos.com-spotify:*:audio/x-spotify:*" duration="0:03:12"&gt;x-sonos-spotify:spotify%3atrack%3a4V0x90QcMh4ZxwHzEWOdtK?sid=12&amp;amp;flags=8232&amp;amp;sn=13&lt;/res&gt;&lt;upnp:albumArtURI&gt;/getaa?s=1&amp;amp;u=x-sonos-spotify%3aspotify%253atrack%253a4V0x90QcMh4ZxwHzEWOdtK&lt;/upnp:albumArtURI&gt;&lt;dc:title&gt;Feel It All Around&lt;/dc:title&gt;&lt;upnp:class&gt;object.item.audioItem.musicTrack&lt;/upnp:class&gt;&lt;dc:creator&gt;Washed Out&lt;/dc:creator&gt;&lt;upnp:album&gt;Life of Leisure&lt;/upnp:album&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</Result>
    <NumberReturned>1</NumberReturned><TotalMatches>1</TotalMatches><UpdateID>7</UpdateID>
    </u:BrowseResponse></s:Body></s:Envelope>
    """

    /// A Sonos playlist, which is a container the player will enumerate.
    static let sonosPlaylists = """
    <?xml version="1.0"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
    <s:Body><u:BrowseResponse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
    <Result>&lt;DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"&gt;&lt;container id="SQ:2" parentID="SQ:" restricted="true"&gt;&lt;dc:title&gt;grief corecore monday late night&lt;/dc:title&gt;&lt;upnp:class&gt;object.container.playlistContainer&lt;/upnp:class&gt;&lt;res protocolInfo="file:*:audio/mpegurl:*"&gt;file:///jffs/settings/savedqueues.rsq#2&lt;/res&gt;&lt;/container&gt;&lt;/DIDL-Lite&gt;</Result>
    <NumberReturned>1</NumberReturned><TotalMatches>1</TotalMatches><UpdateID>3</UpdateID>
    </u:BrowseResponse></s:Body></s:Envelope>
    """

    static func data(_ xml: String) -> Data { Data(xml.utf8) }
}

struct BrowseEnvelopeTests {
    /// The one thing that would silently break every ContentDirectory call: the shared
    /// envelope builder puts `InstanceID` first for the MediaRenderer services, and this
    /// service rejects it.
    @Test func browseEnvelopeOmitsInstanceID() {
        let envelope = SonosSOAP.envelope(action: ContentDirectoryAction.browse(objectID: "FV:2", start: 0, count: 200))
        #expect(!envelope.contains("InstanceID"))
        #expect(envelope.contains("<u:Browse xmlns:u=\"urn:schemas-upnp-org:service:ContentDirectory:1\">"))
        #expect(envelope.contains("<ObjectID>FV:2</ObjectID>"))
        #expect(envelope.contains("<BrowseFlag>BrowseDirectChildren</BrowseFlag>"))
        #expect(envelope.contains("<StartingIndex>0</StartingIndex>"))
        #expect(envelope.contains("<RequestedCount>200</RequestedCount>"))
    }

    /// The MediaRenderer services must keep it - the default on the protocol is what carries
    /// them, so a mistake in that default would show up here.
    @Test func avTransportEnvelopeStillIncludesInstanceID() {
        #expect(SonosSOAP.envelope(action: SonosAction.play).contains("<InstanceID>0</InstanceID>"))
        #expect(SonosSOAP.envelope(action: SonosAction.removeAllTracksFromQueue).contains("<InstanceID>0</InstanceID>"))
    }

    @Test func contentDirectoryControlURL() {
        #expect(SonosService.contentDirectory.controlURL(ip: "192.168.0.137")?.absoluteString ==
                "http://192.168.0.137:1400/MediaServer/ContentDirectory/Control")
    }

    @Test func addURIToQueueArgumentsAreInServiceOrder() {
        let envelope = SonosSOAP.envelope(
            action: SonosAction.addURIToQueue(uri: "x-sonos-spotify:t?sid=12", metadata: "<DIDL/>", desiredFirstTrackNumber: 0, enqueueAsNext: true)
        )
        let order = ["EnqueuedURI", "EnqueuedURIMetaData", "DesiredFirstTrackNumberEnqueued", "EnqueueAsNext"]
        let positions = order.compactMap { envelope.range(of: "<\($0)>")?.lowerBound }
        #expect(positions.count == order.count)
        #expect(positions == positions.sorted())
        // Metadata is arbitrary XML and has to arrive escaped, or it breaks the envelope.
        #expect(envelope.contains("&lt;DIDL/&gt;"))
    }
}

struct DIDLParsingTests {
    @Test func parsesFavoritesIncludingBothServices() {
        let items = SonosContentDirectory.items(fromBrowseResponse: Fixture.data(Fixture.favorites), coordinatorIP: "192.168.0.137")
        #expect(items.count == 2)

        let youTube = items[0]
        #expect(youTube.id == "FV:2/18")
        // Entity-decoded exactly once by the time it reaches the UI.
        #expect(youTube.title == "Acoustic Indie & Alternative")
        #expect(youTube.subtitle == "YouTube Music")
        #expect(youTube.serviceID == 284)
        #expect(youTube.artURL?.absoluteString == "https://lh3.googleusercontent.com/9T5Gi")

        let spotify = items[1]
        #expect(spotify.title == "Classics")
        #expect(spotify.serviceID == 12)
        #expect(spotify.subtitle == "Album by Ratatat")
    }

    /// `r:resMD` is the metadata a favorite must be played with - it carries the credential
    /// token - and it has to come back out as usable DIDL-Lite, unescaped exactly once.
    @Test func favoriteCarriesItsPlaybackMetadataWithCredentialToken() {
        let items = SonosContentDirectory.items(fromBrowseResponse: Fixture.data(Fixture.favorites), coordinatorIP: "10.0.0.1")
        let metadata = try! #require(items[0].playMetadata)
        #expect(metadata.hasPrefix("<DIDL-Lite>"))
        #expect(metadata.contains("<desc id=\"cdudn\""))
        #expect(metadata.contains("SA_RINCON72711_X_#Svc72711-0-Token"))
        // One level of unescaping only: the inner title's literal ampersand survives as an
        // entity, because this string is XML that Sonos will parse again.
        #expect(metadata.contains("Acoustic Indie &amp; Alternative"))
    }

    @Test func favoritePlayURIKeepsItsQuery() {
        let items = SonosContentDirectory.items(fromBrowseResponse: Fixture.data(Fixture.favorites), coordinatorIP: "10.0.0.1")
        #expect(items[0].playURI == "x-rincon-cpcontainer:1006004cALkSOiESaEoG?sid=284&flags=76&sn=3")
    }

    /// The 701 finding, encoded: a favorite pointing at a service container is playable but
    /// not browsable, so the UI must not offer to open it.
    @Test func serviceContainersAreNotExpandable() {
        let items = SonosContentDirectory.items(fromBrowseResponse: Fixture.data(Fixture.favorites), coordinatorIP: "10.0.0.1")
        #expect(items.allSatisfy { !$0.canExpand })
        // Still recognised as an album rather than a song, so it can be drawn as one.
        #expect(items[1].isContainer)
    }

    @Test func sonosPlaylistIsExpandable() {
        let items = SonosContentDirectory.items(fromBrowseResponse: Fixture.data(Fixture.sonosPlaylists), coordinatorIP: "10.0.0.1")
        #expect(items.count == 1)
        #expect(items[0].id == "SQ:2")
        #expect(items[0].isContainer)
        #expect(items[0].canExpand)
    }

    @Test func parsesQueueTrackWithRelativeAlbumArt() {
        let items = SonosContentDirectory.items(fromBrowseResponse: Fixture.data(Fixture.queue), coordinatorIP: "192.168.0.137")
        #expect(items.count == 1)
        let track = items[0]
        #expect(track.id == "Q:0/1")
        #expect(track.title == "Feel It All Around")
        #expect(track.subtitle == "Washed Out")
        #expect(track.album == "Life of Leisure")
        #expect(!track.isContainer)
        #expect(!track.canExpand)
        #expect(track.serviceID == 12)
        // Resolved against the player, and NOT re-encoded - the path already contains %-escapes.
        let art = try! #require(track.artURL?.absoluteString)
        #expect(art.hasPrefix("http://192.168.0.137:1400/getaa?"))
        #expect(art.contains("%253atrack%253a"))
        #expect(!art.contains("%2525"))
    }

    /// Captured live: a track queued from the Spotify app arrives with a `<res>`, art, and
    /// `object.item` - and no `dc:title`, `dc:creator`, or `upnp:album` at all until the player
    /// has filled its metadata in. The row still has to be identifiable and playable.
    @Test func aQueueTrackWithNoMetadataYetStillParses() {
        let untitled = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:BrowseResponse>
        <Result>&lt;DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"&gt;&lt;item id="Q:0/1" parentID="Q:0" restricted="true"&gt;&lt;res protocolInfo="sonos.com-spotify:*:application/octet-stream:*"&gt;x-sonos-spotify:spotify%3atrack%3a4U66PuN4v7VfSI9ZVmNfpw?sid=12&amp;amp;flags=8232&amp;amp;sn=13&lt;/res&gt;&lt;upnp:albumArtURI&gt;/getaa?s=1&amp;amp;u=x-sonos-spotify%3aspotify%253atrack%253a4U66PuN4v7VfSI9ZVmNfpw&lt;/upnp:albumArtURI&gt;&lt;upnp:class&gt;object.item&lt;/upnp:class&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</Result>
        <NumberReturned>1</NumberReturned><TotalMatches>1</TotalMatches></u:BrowseResponse></s:Body></s:Envelope>
        """
        let items = SonosContentDirectory.items(fromBrowseResponse: Fixture.data(untitled), coordinatorIP: "10.0.0.1")
        #expect(items.count == 1)
        // The absence is preserved rather than papered over in the parser...
        #expect(items[0].title.isEmpty)
        #expect(items[0].subtitle == nil)
        #expect(items[0].album == nil)
        // ...and turned into something readable at the point of display.
        #expect(items[0].displayTitle == "Unknown Track")
        #expect(items[0].isPlayable)
        #expect(items[0].serviceID == 12)
    }

    @Test func anUntitledContainerReadsAsUntitledRatherThanUnknownTrack() {
        let container = MediaItem(id: "SQ:9", title: "", isContainer: true, canExpand: true)
        #expect(container.displayTitle == "Untitled")
    }

    @Test func emptyResultParsesToNoItems() {
        let empty = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>
        <u:BrowseResponse><Result></Result><NumberReturned>0</NumberReturned><TotalMatches>0</TotalMatches>
        </u:BrowseResponse></s:Body></s:Envelope>
        """
        #expect(SonosContentDirectory.items(fromBrowseResponse: Fixture.data(empty), coordinatorIP: "10.0.0.1").isEmpty)
    }

    @Test func garbageResponseParsesToNoItemsRatherThanTrapping() {
        #expect(SonosContentDirectory.items(fromBrowseResponse: Data("not xml at all".utf8), coordinatorIP: "10.0.0.1").isEmpty)
    }
}

struct DIDLURIFieldTests {
    @Test func readsServiceIDAndAccountSerial() {
        let uri = "x-sonos-spotify:spotify%3atrack%3a4V0x90QcMh4ZxwHzEWOdtK?sid=12&flags=8232&sn=13"
        #expect(DIDL.serviceID(inPlayURI: uri) == 12)
        #expect(DIDL.accountSerial(inPlayURI: uri) == "13")
    }

    @Test func aURIWithNoQueryHasNeither() {
        let uri = "file:///jffs/settings/savedqueues.rsq#2"
        #expect(DIDL.serviceID(inPlayURI: uri) == nil)
        #expect(DIDL.accountSerial(inPlayURI: uri) == nil)
    }

    /// The value has to be matched on the whole parameter name: `sn` must not be found by a
    /// naive search that also matches inside `sid`.
    @Test func parameterNamesMatchWholeKeys() {
        #expect(DIDL.accountSerial(inPlayURI: "x-y:z?sid=284&flags=76&sn=3") == "3")
        #expect(DIDL.serviceID(inPlayURI: "x-y:z?snid=99&sid=7") == 7)
    }

    @Test func absoluteArtURLIsUsedUnchanged() {
        #expect(DIDL.artURL(from: "https://example.com/a.jpg", coordinatorIP: "10.0.0.1")?.absoluteString
                == "https://example.com/a.jpg")
    }

    @Test func nilArtStaysNil() {
        #expect(DIDL.artURL(from: nil, coordinatorIP: "10.0.0.1") == nil)
    }
}
