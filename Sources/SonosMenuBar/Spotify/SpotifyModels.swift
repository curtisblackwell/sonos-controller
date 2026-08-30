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
        let name: String
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

        struct Owner: Decodable {
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

    struct PlaylistTrackItem: Decodable {
        let track: Track?
    }
}
