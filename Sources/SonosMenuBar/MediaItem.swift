import Foundation

/// One row in any browse list: a favorite, a Sonos playlist, a track in the queue, an album
/// that came back from a search. Whatever produced it, this is what the list views render and
/// what `SonosQueue` knows how to play.
///
/// `playURI` and `playMetadata` are the pair `SetAVTransportURI` and `AddURIToQueue` take.
/// Sonos stores both for everything already on the household - a favorite pointing at a
/// Spotify playlist carries the URI *and* the DIDL-Lite it needs, including the credential
/// token - so replaying one requires knowing nothing about the service behind it. Items we
/// build ourselves from a service API have to synthesize the same pair.
struct MediaItem: Equatable, Identifiable {
    /// The DIDL `id` attribute, which for Sonos-native content is also the ObjectID to browse
    /// into (`SQ:2`, `Q:0/1`, `A:ALBUM/…`).
    let id: String
    let title: String
    /// Artist for a track, owner or service name for a container - whatever the second line
    /// should read.
    let subtitle: String?
    /// A track's album name, shown under `subtitle` as a second, subtler line. `nil` for
    /// anything that isn't a track, or whose album wasn't given.
    let album: String?
    let artURL: URL?
    let playURI: String?
    let playMetadata: String?
    let isContainer: Bool
    /// An album's release date, as Spotify gives it - `"2026"`, `"2026-08"`, or `"2026-08-29"`
    /// depending on how precisely the release is dated. `nil` for anything that isn't an album.
    let releaseDate: String?
    /// Whether browsing into `id` will actually return children.
    ///
    /// Only true for content the player itself holds: Sonos playlists, the queue, the local
    /// library. A third-party service container - a Spotify album, a YouTube Music playlist -
    /// is a container the player can *play* but not enumerate: `Browse` on its ObjectID
    /// returns UPnP error 701, no such object. Offering a drill-in for one would be offering
    /// a dead end, so the flag is what the UI gates navigation on.
    let canExpand: Bool
    /// The music service id from `playURI`'s query, when there is one. `nil` for local
    /// library content and for the queue's own container.
    let serviceID: Int?

    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        album: String? = nil,
        artURL: URL? = nil,
        playURI: String? = nil,
        playMetadata: String? = nil,
        isContainer: Bool = false,
        canExpand: Bool = false,
        serviceID: Int? = nil,
        releaseDate: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.album = album
        self.artURL = artURL
        self.playURI = playURI
        self.playMetadata = playMetadata
        self.isContainer = isContainer
        self.canExpand = canExpand
        self.serviceID = serviceID
        self.releaseDate = releaseDate
    }

    var isPlayable: Bool { playURI != nil }

    /// This item's 1-based position in the queue, if it is a queue row.
    ///
    /// Queue ids are `Q:0/1`, `Q:0/2`, and so on, and that number is the track number `Seek`
    /// takes - which is what makes "play this" on a queue row a jump rather than an edit. The
    /// numbering is absolute, so it stays correct when a list was fetched with a non-zero
    /// starting index.
    var queuePosition: Int? {
        let prefix = "Q:0/"
        guard id.hasPrefix(prefix) else { return nil }
        return Int(id.dropFirst(prefix.count))
    }

    /// What a row should read. `title` is left exactly as DIDL gave it, empty included,
    /// because "no title" is real: a queue row can arrive as
    /// `<item><res/><upnp:albumArtURI/><upnp:class>object.item</upnp:class></item>` with no
    /// `dc:title` at all - and for a track this app itself queued, `Browse` never fills it in
    /// afterwards either (see `SpotifyQueuedTrackCache`, which is what patches those rows back
    /// up before they reach display). Rendering the gap as a blank row looks like a bug in this
    /// app rather than what it is.
    var displayTitle: String {
        title.isEmpty ? (isContainer ? "Untitled" : "Unknown Track") : title
    }
}
