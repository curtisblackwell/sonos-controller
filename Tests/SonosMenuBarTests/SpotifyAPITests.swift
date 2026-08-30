import Testing
import Foundation
@testable import SonosMenuBar

struct SpotifyAPITests {
    @Test func retryDelayUsesRetryAfterHeader() {
        #expect(SpotifyAPI.retryDelay(retryAfterHeader: "3") == 3)
    }

    @Test func retryDelayFallsBackWhenHeaderMissingOrUnparseable() {
        #expect(SpotifyAPI.retryDelay(retryAfterHeader: nil) == 1)
        #expect(SpotifyAPI.retryDelay(retryAfterHeader: "not-a-number") == 1)
    }

    /// Shaped like a real `/v1/search?type=track,album,playlist` response, trimmed to the
    /// fields this app reads.
    @Test func decodesSearchResponse() throws {
        let json = """
        {
          "tracks": { "items": [
            { "id": "4V0x90QcMh4ZxwHzEWOdtK", "name": "Feel It All Around", "uri": "spotify:track:4V0x90QcMh4ZxwHzEWOdtK",
              "artists": [ { "name": "Washed Out" } ],
              "album": { "name": "Life of Leisure", "images": [ { "url": "https://i.scdn.co/image/abc" } ] } }
          ] },
          "albums": { "items": [
            { "id": "7cKqnavORKemYZ41wFtx5J", "name": "Classics", "uri": "spotify:album:7cKqnavORKemYZ41wFtx5J",
              "images": [ { "url": "https://i.scdn.co/image/def" } ], "artists": [ { "name": "Ratatat" } ] }
          ] },
          "playlists": { "items": [
            { "id": "37i9dQZF1", "name": "Discover Weekly", "uri": "spotify:playlist:37i9dQZF1",
              "images": [ { "url": "https://i.scdn.co/image/ghi" } ], "owner": { "display_name": "Spotify" } }
          ] }
        }
        """
        let response = try JSONDecoder().decode(SpotifyModels.SearchResponse.self, from: Data(json.utf8))
        #expect(response.tracks?.items.first??.name == "Feel It All Around")
        #expect(response.tracks?.items.first??.artists.first?.name == "Washed Out")
        #expect(response.albums?.items.first??.name == "Classics")
        #expect(response.playlists?.items.first??.owner?.display_name == "Spotify")
    }

    /// A search result's own items can contain `null` entries - a playlist that's since been
    /// deleted or made private is the common case - and decoding the whole response must not
    /// fail because of it.
    @Test func decodesSearchResponseWithANullPlaylistItem() throws {
        let json = """
        {
          "playlists": { "items": [
            null,
            { "id": "37i9dQZF1", "name": "Discover Weekly", "uri": "spotify:playlist:37i9dQZF1",
              "images": [ { "url": "https://i.scdn.co/image/ghi" } ], "owner": { "display_name": "Spotify" } }
          ] }
        }
        """
        let response = try JSONDecoder().decode(SpotifyModels.SearchResponse.self, from: Data(json.utf8))
        #expect(response.playlists?.items.count == 2)
        #expect(response.playlists?.items.compactMap { $0 }.count == 1)
    }

    /// A playlist's `track` can be null - a removed local file leaves a hole in the list - and
    /// decoding the response must not fail because of it.
    @Test func decodesPlaylistItemsWithANullTrack() throws {
        let json = """
        { "items": [
          { "track": null },
          { "track": { "id": "abc", "name": "Song", "uri": "spotify:track:abc", "artists": [], "album": null } }
        ] }
        """
        let page = try JSONDecoder().decode(SpotifyModels.Paging<SpotifyModels.PlaylistTrackItem>.self, from: Data(json.utf8))
        #expect(page.items.count == 2)
        #expect(page.items.compactMap(\.track).count == 1)
    }
}
