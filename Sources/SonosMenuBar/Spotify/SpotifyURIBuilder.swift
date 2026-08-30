import Foundation

/// Turns a Spotify track into the `(playURI, playMetadata)` pair `SonosQueue` already knows
/// how to play, using nothing SonosQueue doesn't already understand.
///
/// `sid` (the music service id) and `sn` (the linked account's serial number) are per-household
/// and there is no API that reports them - see `DIDL.accountSerial`'s doc comment. The only way
/// to learn them is to read them off Spotify content the household already has.
///
/// No `playMetadata` is synthesized. Two real captured fixtures confirm Sonos plays a
/// `x-sonos-spotify:` URI carrying `sid`/`sn` with no `r:resMD` at all - a favorite pointing at
/// a Spotify album (`ContentDirectoryTests.favorites`) and a Spotify queue track
/// (`ContentDirectoryTests.queue`) both have none. Inventing metadata with an unverified shape
/// risks the player rejecting the call outright, which is worse than the title arriving a
/// moment later the way it already does for anything queued from the Spotify app itself (see
/// `MediaItem.displayTitle`'s doc comment).
enum SpotifyURIBuilder {
    /// The `flags` value for a single track, confirmed from a real captured queue-track fixture
    /// (`x-sonos-spotify:spotify%3atrack%3a…?sid=12&flags=8232&sn=13`). Containers (albums,
    /// playlists) use different flags this app has no captured fixture for, so building a
    /// container URI is deliberately not offered here.
    private static let trackFlags = 8232

    /// Scans an already-fetched list of Sonos `MediaItem`s (favorites, Sonos playlist tracks,
    /// the queue) for the first one that names a Spotify service, and reads its `sid`/`sn` off
    /// the URI. `nil` means Spotify has no linked content in what was scanned yet.
    static func householdCredentials(scanning items: [MediaItem]) -> (sid: Int, sn: String)? {
        for item in items {
            guard let uri = item.playURI, uri.localizedCaseInsensitiveContains("spotify") else { continue }
            guard let sid = DIDL.serviceID(inPlayURI: uri), let sn = DIDL.accountSerial(inPlayURI: uri) else { continue }
            return (sid, sn)
        }
        return nil
    }

    /// `spotifyTrackID` is the bare id (`4V0x90QcMh4ZxwHzEWOdtK`), not the `spotify:track:…` URI.
    static func playURI(spotifyTrackID: String, sid: Int, sn: String) -> String {
        "x-sonos-spotify:spotify%3atrack%3a\(spotifyTrackID)?sid=\(sid)&flags=\(trackFlags)&sn=\(sn)"
    }
}
