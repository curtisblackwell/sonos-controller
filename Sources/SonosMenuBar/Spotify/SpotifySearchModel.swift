import Foundation
import os.log

/// The state behind Spotify search: submit a query, open an album or playlist to see its
/// tracks, play one through the active Sonos group. Mirrors the subset of `BrowseModel`'s
/// surface `MediaListView` needs (`MediaBrowsing`) but fetches from Spotify's Web API rather
/// than a Sonos player, and reuses `SonosQueue` unchanged to actually play something - a
/// Spotify-sourced `MediaItem` is playable the same way any other one is, once it carries a
/// `playURI`.
///
/// Main thread only, same as `BrowseModel`: completions from `SpotifyAPI` and
/// `SonosContentDirectory` land on a URLSession queue and hop back here.
final class SpotifySearchModel: ObservableObject {
    private static let log = Logger(subsystem: "com.curtisblackwell.sonos-controller", category: "spotify-search")
    private static let rootLevel = BrowseModel.Level(objectID: "SPOTIFY:root", title: "Spotify")

    let auth: SpotifyAuth
    /// Shared with `BrowseModel`, which reads it back for queue rows `Browse` can't title -
    /// see `SpotifyQueuedTrackCache`'s doc comment.
    private let metadataCache: SpotifyQueuedTrackCache

    @Published private(set) var path: [BrowseModel.Level] = [rootLevel]
    @Published private(set) var items: [MediaItem]? = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var filter = ""

    private var coordinatorIP: String?
    private var generation = 0

    /// The household's Spotify `sid`/`sn`, read once off content the Sonos player already
    /// knows about - see `SpotifyURIBuilder`. `nil` after a completed attempt means none was
    /// found, not that the attempt hasn't happened yet.
    private var credentials: (sid: Int, sn: String)?
    private var didAttemptCredentialDiscovery = false

    /// Art/title for whichever album or playlist is currently open, so its tracks can show art
    /// even when Spotify's own "tracks of an album" response omits the album object.
    private var openContainerArt: URL?

    /// Set for the header `SpotifySearchPage` shows above an open album's tracks - `nil` for
    /// anything else that's open (a playlist, or nothing).
    struct AlbumHeader: Equatable {
        let title: String
        let artist: String?
        let artURL: URL?
        let releaseDate: String?
    }

    @Published private(set) var openAlbum: AlbumHeader?

    init(auth: SpotifyAuth, metadataCache: SpotifyQueuedTrackCache) {
        self.auth = auth
        self.metadataCache = metadataCache
    }

    var currentLevel: BrowseModel.Level? { path.last }

    var visibleItems: [MediaItem] { items ?? [] }

    // MARK: - Topology

    func update(coordinatorIP: String?) {
        self.coordinatorIP = coordinatorIP
    }

    // MARK: - Searching

    func search() {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        path = [Self.rootLevel]
        openAlbum = nil
        guard !query.isEmpty else {
            items = []
            return
        }
        generation += 1
        let requestGeneration = generation
        isLoading = true
        items = nil

        withCredentials { [weak self] in
            guard let self else { return }
            SpotifyAPI.search(query: query, auth: self.auth) { result in
                DispatchQueue.main.async {
                    guard requestGeneration == self.generation else { return }
                    self.isLoading = false
                    switch result {
                    case let .success(response):
                        self.items = self.mediaItems(from: response)
                    case let .failure(error):
                        Self.log.error("Spotify search failed: \(error.localizedDescription, privacy: .public)")
                        self.items = []
                        self.errorMessage = "Couldn't search Spotify: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    // MARK: - Navigation

    func open(_ item: MediaItem) {
        guard item.canExpand else { return }
        let title = item.displayTitle
        openContainerArt = item.artURL
        openAlbum = item.id.hasPrefix("SPOTIFY:album:")
            ? AlbumHeader(title: title, artist: item.subtitle, artURL: item.artURL, releaseDate: item.releaseDate)
            : nil
        path.append(BrowseModel.Level(objectID: item.id, title: title))
        loadContainer(id: item.id)
    }

    func pop(to index: Int) {
        guard index >= 0, index < path.count, index != path.count - 1 else { return }
        path = Array(path.prefix(index + 1))
        if let level = currentLevel, level.objectID != Self.rootLevel.objectID {
            loadContainer(id: level.objectID)
        } else {
            openAlbum = nil
            search()
        }
    }

    private func loadContainer(id: String) {
        generation += 1
        let requestGeneration = generation
        isLoading = true
        items = nil

        withCredentials { [weak self] in
            guard let self else { return }
            let completion: (Result<[SpotifyModels.Track], Error>) -> Void = { result in
                DispatchQueue.main.async {
                    guard requestGeneration == self.generation else { return }
                    self.isLoading = false
                    switch result {
                    case let .success(tracks):
                        self.items = tracks.map { self.mediaItem(from: $0) }
                    case let .failure(error):
                        Self.log.error("Spotify container fetch failed: \(error.localizedDescription, privacy: .public)")
                        self.items = []
                        self.errorMessage = "Couldn't load that: \(error.localizedDescription)"
                    }
                }
            }
            if id.hasPrefix("SPOTIFY:album:") {
                let spotifyID = String(id.dropFirst("SPOTIFY:album:".count))
                SpotifyAPI.albumTracks(id: spotifyID, auth: self.auth) { completion($0.map(\.items)) }
            } else if id.hasPrefix("SPOTIFY:playlist:") {
                let spotifyID = String(id.dropFirst("SPOTIFY:playlist:".count))
                SpotifyAPI.playlistItems(id: spotifyID, auth: self.auth) { result in
                    completion(result.map { $0.items.compactMap(\.track) })
                }
            }
        }
    }

    // MARK: - Playing

    func play(_ item: MediaItem, intent: PlayIntent, coordinatorUUID: String?) {
        guard let coordinatorUUID, let ip = coordinatorIP else {
            errorMessage = "Pick a group for the media keys first - that's where music plays."
            return
        }
        guard item.playURI != nil else {
            errorMessage = "Play something from Spotify in the Sonos app once (or add a Spotify favorite), so this app can find your linked account."
            return
        }
        let commands = SonosQueue.commands(for: item, intent: intent, coordinatorUUID: coordinatorUUID)
        SonosQueue.perform(commands, coordinatorIP: ip) { [weak self] result in
            if case let .failure(error) = result {
                self?.errorMessage = "Couldn't play \(item.displayTitle): \(error.localizedDescription)"
            }
        }
    }

    /// The open album's "Play Album" button: replaces the queue with its tracks and starts it.
    func playAlbum(coordinatorUUID: String?) {
        guard let coordinatorUUID, let ip = coordinatorIP else {
            errorMessage = "Pick a group for the media keys first - that's where music plays."
            return
        }
        let commands = SonosQueue.commands(forAlbumTracks: items ?? [], coordinatorUUID: coordinatorUUID)
        guard !commands.isEmpty else {
            errorMessage = "Play something from Spotify in the Sonos app once (or add a Spotify favorite), so this app can find your linked account."
            return
        }
        SonosQueue.perform(commands, coordinatorIP: ip) { [weak self] result in
            if case let .failure(error) = result {
                self?.errorMessage = "Couldn't play the album: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Credential discovery

    /// Scans Favorites, then Sonos Playlists, then the Queue for the first Spotify `sid`/`sn`
    /// pair, once per app launch. Runs `then` either way - a household with nothing Spotify
    /// linked still gets search results, just none of them playable.
    private func withCredentials(then: @escaping () -> Void) {
        guard !didAttemptCredentialDiscovery, credentials == nil else {
            then()
            return
        }
        guard let ip = coordinatorIP else {
            then()
            return
        }
        let roots = [
            SonosContentDirectory.ObjectID.favorites,
            SonosContentDirectory.ObjectID.sonosPlaylists,
            SonosContentDirectory.ObjectID.queue,
        ]
        scanForCredentials(roots: roots, index: 0, ip: ip, then: then)
    }

    private func scanForCredentials(roots: [String], index: Int, ip: String, then: @escaping () -> Void) {
        guard index < roots.count else {
            DispatchQueue.main.async { [weak self] in
                self?.didAttemptCredentialDiscovery = true
                then()
            }
            return
        }
        SonosContentDirectory.browseAll(objectID: roots[index], from: ip) { [weak self] result in
            guard let self else { return }
            if case let .success(items) = result,
               let found = SpotifyURIBuilder.householdCredentials(scanning: items) {
                DispatchQueue.main.async {
                    self.credentials = found
                    self.didAttemptCredentialDiscovery = true
                    then()
                }
                return
            }
            DispatchQueue.main.async {
                self.scanForCredentials(roots: roots, index: index + 1, ip: ip, then: then)
            }
        }
    }

    // MARK: - Mapping

    private func mediaItems(from response: SpotifyModels.SearchResponse) -> [MediaItem] {
        let tracks = (response.tracks?.items ?? []).compactMap { $0 }.map { mediaItem(from: $0) }
        let albums = (response.albums?.items ?? []).compactMap { $0 }.map { mediaItem(from: $0) }
        let playlists = (response.playlists?.items ?? []).compactMap { $0 }.map { mediaItem(from: $0) }
        return tracks + albums + playlists
    }

    private func mediaItem(from track: SpotifyModels.Track) -> MediaItem {
        let artURL = track.album?.images?.first.flatMap { URL(string: $0.url) } ?? openContainerArt
        var playURI: String?
        if let credentials {
            playURI = SpotifyURIBuilder.playURI(spotifyTrackID: track.id, sid: credentials.sid, sn: credentials.sn)
        }
        let item = MediaItem(
            id: "SPOTIFY:track:\(track.id)",
            title: track.name,
            subtitle: track.artists.map(\.name).joined(separator: ", "),
            album: track.album?.name,
            artURL: artURL,
            playURI: playURI,
            isContainer: false,
            canExpand: false
        )
        // However this track ends up queued - a direct play, "Play Next", or a whole album -
        // this is the one point every track passes through, so it's remembered here rather
        // than at each call site that might queue it.
        metadataCache.remember(item)
        return item
    }

    private func mediaItem(from album: SpotifyModels.Album) -> MediaItem {
        MediaItem(
            id: "SPOTIFY:album:\(album.id)",
            title: album.name,
            subtitle: album.artists.map(\.name).joined(separator: ", "),
            artURL: album.images?.first.flatMap { URL(string: $0.url) },
            isContainer: true,
            canExpand: true,
            releaseDate: album.release_date
        )
    }

    private func mediaItem(from playlist: SpotifyModels.Playlist) -> MediaItem {
        MediaItem(
            id: "SPOTIFY:playlist:\(playlist.id)",
            title: playlist.name,
            subtitle: playlist.owner?.display_name,
            artURL: playlist.images?.first.flatMap { URL(string: $0.url) },
            isContainer: true,
            canExpand: true
        )
    }
}

extension SpotifySearchModel: MediaBrowsing {}
