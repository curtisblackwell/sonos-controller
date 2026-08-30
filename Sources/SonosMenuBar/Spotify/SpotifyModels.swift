import Foundation

/// The subset of Spotify's Web API JSON this app needs: search results, the user's playlists
/// and saved albums, and the tracks inside a container. Everything else in a Spotify response
/// is simply not decoded.
enum SpotifyModels {
    struct Paging<Item: Decodable>: Decodable {
        let items: [Item]
    }

    struct Image: Decodable {
        let url: String
    }

    struct Artist: Decodable {
        let id: String
        let name: String
        let uri: String
        /// Present on a full artist object (top artists, following); absent on the simplified
        /// artist refs nested in a track/album, so this stays optional.
        let images: [Image]?
    }

    struct AlbumRef: Decodable {
        let name: String
        let images: [Image]?
    }

    struct Track: Decodable {
        let id: String
        let name: String
        let uri: String
        let artists: [Artist]
        let album: AlbumRef?
    }

    struct Album: Decodable {
        let id: String
        let name: String
        let uri: String
        let images: [Image]?
        let artists: [Artist]
        /// `"2026"`, `"2026-08"`, or `"2026-08-29"`, depending on `release_date_precision` -
        /// which this app doesn't decode, since the string's own length already says which.
        let release_date: String?
    }

    struct Playlist: Decodable {
        let id: String
        let name: String
        let uri: String
        let images: [Image]?
        let owner: Owner?
        /// As of Spotify's February 2026 Development Mode migration, `/playlists/{id}/items`
        /// 403s for any playlist the user neither owns nor collaborates on - so this and
        /// `owner.id` are what a Development Mode app filters on before offering a playlist to
        /// open, rather than only finding out via the failed request.
        let collaborative: Bool

        struct Owner: Decodable {
            let id: String
            let display_name: String?
        }
    }

    /// Search results can contain `null` entries - most commonly a playlist that has since been
    /// deleted or made private - so every item here is optional rather than the search endpoint
    /// failing to decode outright over one missing item.
    struct SearchResponse: Decodable {
        let tracks: Paging<Track?>?
        let albums: Paging<Album?>?
        let playlists: Paging<Playlist?>?
    }

    struct SavedAlbumItem: Decodable {
        let album: Album
    }

    /// `track` is deprecated in favor of `item` (a `Track` or an episode) - decoded as `Track`
    /// directly since `item` is a top-level field here, not the `track`-shaped wrapper it used
    /// to be. An episode won't decode as `Track` (no `artists`/`album`), so it comes through as
    /// `nil` rather than failing the whole page.
    struct PlaylistTrackItem: Decodable {
        let item: Track?

        private enum CodingKeys: String, CodingKey { case item }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            item = try? container.decode(Track.self, forKey: .item)
        }
    }

    struct User: Decodable {
        let id: String
    }

    /// `/me/following`'s cursor-paged shape - nests the artist list one level deeper than every
    /// other endpoint here, under a key naming the type that was requested.
    struct FollowedArtistsResponse: Decodable {
        let artists: Paging<Artist>
    }
}
