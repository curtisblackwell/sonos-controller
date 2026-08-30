import Testing
import Foundation
@testable import SonosMenuBar

private let trackURI = "x-sonos-spotify:spotify%3atrack%3a4V0x90QcMh4ZxwHzEWOdtK?sid=12&flags=8232&sn=13"

private func knownTrack(id: String = "Q:0/1") -> MediaItem {
    MediaItem(
        id: id,
        title: "Feel It All Around",
        subtitle: "Washed Out",
        album: "Life of Leisure",
        artURL: URL(string: "https://example.com/art.jpg"),
        playURI: trackURI
    )
}

private func blankQueueRow(id: String = "Q:0/1") -> MediaItem {
    MediaItem(id: id, title: "", playURI: trackURI)
}

struct SpotifyTrackIDParsingTests {
    @Test func extractsTheBareIDFromAPlayURI() {
        #expect(DIDL.spotifyTrackID(inPlayURI: trackURI) == "4V0x90QcMh4ZxwHzEWOdtK")
    }

    @Test func nonSpotifyURIsHaveNoID() {
        #expect(DIDL.spotifyTrackID(inPlayURI: "x-rincon-cpcontainer:1006004cX?sid=284&sn=3") == nil)
    }
}

struct SpotifyQueuedTrackCacheTests {
    @Test func fillsInABlankQueueRowFromARememberedTrack() {
        let cache = SpotifyQueuedTrackCache()
        cache.remember(knownTrack())

        let filled = cache.fillGaps(in: blankQueueRow())
        #expect(filled.title == "Feel It All Around")
        #expect(filled.subtitle == "Washed Out")
        #expect(filled.album == "Life of Leisure")
        #expect(filled.artURL?.absoluteString == "https://example.com/art.jpg")
        // Everything needed to still play the row is untouched.
        #expect(filled.id == "Q:0/1")
        #expect(filled.playURI == trackURI)
    }

    @Test func leavesARowAloneWhenBrowseAlreadyKnowsItsTitle() {
        let cache = SpotifyQueuedTrackCache()
        cache.remember(knownTrack())

        let alreadyTitled = MediaItem(id: "Q:0/1", title: "Some Other Title", playURI: trackURI)
        #expect(cache.fillGaps(in: alreadyTitled) == alreadyTitled)
    }

    @Test func leavesABlankRowAloneWhenNothingWasRemembered() {
        let cache = SpotifyQueuedTrackCache()
        let untouched = blankQueueRow()
        #expect(cache.fillGaps(in: untouched) == untouched)
    }

    @Test func neverRemembersATrackThatHasNoTitleItself() {
        let cache = SpotifyQueuedTrackCache()
        cache.remember(blankQueueRow())
        #expect(cache.fillGaps(in: blankQueueRow()) == blankQueueRow())
    }

    /// The cache is keyed by track id, not queue position - the same track can be looked up
    /// under a different `Q:0/N` row once it's moved or re-added.
    @Test func matchesByTrackIDRegardlessOfQueuePosition() {
        let cache = SpotifyQueuedTrackCache()
        cache.remember(knownTrack(id: "Q:0/1"))
        let filled = cache.fillGaps(in: blankQueueRow(id: "Q:0/7"))
        #expect(filled.title == "Feel It All Around")
        #expect(filled.id == "Q:0/7")
    }
}
