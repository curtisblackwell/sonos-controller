import Testing
import Foundation
@testable import SonosMenuBar

struct SpotifyURIBuilderTests {
    /// Matches the shape captured in `ContentDirectoryTests.queue`:
    /// `x-sonos-spotify:spotify%3atrack%3a4V0x90QcMh4ZxwHzEWOdtK?sid=12&flags=8232&sn=13`.
    @Test func playURIMatchesCapturedFixtureShape() {
        let uri = SpotifyURIBuilder.playURI(spotifyTrackID: "4V0x90QcMh4ZxwHzEWOdtK", sid: 12, sn: "13")
        #expect(uri == "x-sonos-spotify:spotify%3atrack%3a4V0x90QcMh4ZxwHzEWOdtK?sid=12&flags=8232&sn=13")
    }

    @Test func householdCredentialsReadSidAndSnFromASpotifyItem() {
        let items = [
            MediaItem(id: "FV:2/18", title: "Acoustic Indie", playURI: "x-rincon-cpcontainer:1006004cALkSOiESaEoG?sid=284&flags=76&sn=3"),
            MediaItem(
                id: "FV:2/30",
                title: "Classics",
                playURI: "x-rincon-cpcontainer:00040000spotify%3aalbum%3a7cKqnavORKemYZ41wFtx5J?sid=12&flags=4&sn=13"
            ),
        ]
        let credentials = SpotifyURIBuilder.householdCredentials(scanning: items)
        #expect(credentials?.sid == 12)
        #expect(credentials?.sn == "13")
    }

    @Test func householdCredentialsReadFromAQueueTrackToo() {
        let items = [
            MediaItem(
                id: "Q:0/1",
                title: "Feel It All Around",
                playURI: "x-sonos-spotify:spotify%3atrack%3a4V0x90QcMh4ZxwHzEWOdtK?sid=12&flags=8232&sn=13"
            ),
        ]
        let credentials = SpotifyURIBuilder.householdCredentials(scanning: items)
        #expect(credentials?.sid == 12)
        #expect(credentials?.sn == "13")
    }

    @Test func householdCredentialsIsNilWithNoSpotifyItem() {
        let items = [
            MediaItem(id: "SQ:2", title: "Sonos Playlist", playURI: "file:///jffs/settings/savedqueues.rsq#2"),
        ]
        #expect(SpotifyURIBuilder.householdCredentials(scanning: items) == nil)
    }
}
