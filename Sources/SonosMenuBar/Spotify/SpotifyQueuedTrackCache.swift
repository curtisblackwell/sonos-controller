import Foundation

/// Title/artist/album/art for tracks this app has queued via Spotify, keyed by the bare
/// Spotify track id embedded in its `x-sonos-spotify:` play URI.
///
/// The Sonos queue's own `Browse` never learns this on its own: `AddURIToQueue` here carries
/// no `resMD` (see `SpotifyURIBuilder`'s doc comment), and unlike `GetPositionInfo`'s live
/// `TrackMetaData` - which the player resolves for itself while actually streaming, and which
/// is what `NowPlayingBar` shows - a queue row's stored DIDL is exactly what was there when it
/// was added, and is never updated afterwards. So a track this app queued stays blank through
/// `Browse` forever, not just until the player catches up.
///
/// This is the app's own memory of what it queued: `SpotifySearchModel` fills it in as it maps
/// search and album results into playable tracks, and `BrowseModel` reads it back whenever the
/// queue's `Browse` response has nothing for a row.
final class SpotifyQueuedTrackCache {
    struct Info {
        let title: String
        let artist: String?
        let album: String?
        let artURL: URL?
    }

    private var byTrackID: [String: Info] = [:]

    /// Records what's known about a Spotify track the moment it's mapped into a `MediaItem`,
    /// so it's available however the track later ends up queued - a direct play, "Play Next",
    /// or as part of an album played in full.
    func remember(_ item: MediaItem) {
        guard !item.title.isEmpty, let uri = item.playURI, let id = DIDL.spotifyTrackID(inPlayURI: uri) else { return }
        byTrackID[id] = Info(title: item.title, artist: item.subtitle, album: item.album, artURL: item.artURL)
    }

    /// Fills in a queue row's title/artist/album/art from what was remembered, if `Browse`
    /// came back with nothing for it. Leaves anything `Browse` did know alone.
    func fillGaps(in item: MediaItem) -> MediaItem {
        guard item.title.isEmpty, let uri = item.playURI,
              let id = DIDL.spotifyTrackID(inPlayURI: uri), let info = byTrackID[id]
        else { return item }
        return MediaItem(
            id: item.id,
            title: info.title,
            subtitle: item.subtitle ?? info.artist,
            album: item.album ?? info.album,
            artURL: item.artURL ?? info.artURL,
            playURI: item.playURI,
            playMetadata: item.playMetadata,
            isContainer: item.isContainer,
            canExpand: item.canExpand,
            serviceID: item.serviceID,
            releaseDate: item.releaseDate
        )
    }
}
