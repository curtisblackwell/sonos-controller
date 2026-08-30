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

    /// The signed-in user's own Spotify id, needed to tell an owned/collaborative playlist
    /// (openable) from one merely followed (403s on `/items` in Development Mode) - see
    /// `isListable`. `nil` after a completed attempt means the lookup failed, not that it
    /// hasn't happened yet.
    private var userID: String?
    private var didAttemptUserIDFetch = false

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
            loadHome()
            return
        }
        generation += 1
        let requestGeneration = generation
        isLoading = true
        items = nil

        withUserID { [weak self] in
            guard let self else { return }
            self.withCredentials { [weak self] in
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
    }

    // MARK: - Home

    /// Called from the page's `.onAppear` - reloads the home sections only when there's a home
    /// to show, so reappearing mid-search or mid-browse doesn't clobber where the user is.
    func showHomeIfAtRoot() {
        guard path.count == 1, filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        loadHome()
    }

    /// The Spotify root's default view once there's no search query: the user's own library at
    /// a glance. All four fetches run together rather than one after another - nothing here
    /// depends on another's result - and land in one `items` update rather than one per
    /// endpoint, so the list doesn't visibly assemble section by section.
    private func loadHome() {
        generation += 1
        let requestGeneration = generation
        isLoading = true
        items = nil

        withUserID { [weak self] in
            guard let self else { return }
            self.withCredentials { [weak self] in
                guard let self else { return }
                var playlists: [MediaItem] = []
                var following: [MediaItem] = []
                var topArtists: [MediaItem] = []
                var topTracks: [MediaItem] = []
                let group = DispatchGroup()

                group.enter()
                SpotifyAPI.myPlaylists(auth: self.auth) { result in
                    if case let .success(page) = result {
                        playlists = page.items.filter(self.isListable).map { self.mediaItem(from: $0) }
                    }
                    group.leave()
                }
                group.enter()
                SpotifyAPI.following(auth: self.auth) { result in
                    if case let .success(response) = result {
                        following = response.artists.items.map { self.mediaItem(from: $0, category: .followedArtist) }
                    }
                    group.leave()
                }
                group.enter()
                SpotifyAPI.topArtists(auth: self.auth) { result in
                    if case let .success(page) = result {
                        topArtists = page.items.map { self.mediaItem(from: $0, category: .topArtist) }
                    }
                    group.leave()
                }
                group.enter()
                SpotifyAPI.topTracks(auth: self.auth) { result in
                    if case let .success(page) = result {
                        topTracks = page.items.map { self.mediaItem(from: $0, category: .topTrack) }
                    }
                    group.leave()
                }
                group.notify(queue: .main) {
                    guard requestGeneration == self.generation else { return }
                    self.isLoading = false
                    self.items = playlists + following + topArtists + topTracks
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
            let completion: (Result<[MediaItem], Error>) -> Void = { result in
                DispatchQueue.main.async {
                    guard requestGeneration == self.generation else { return }
                    self.isLoading = false
                    switch result {
                    case let .success(mediaItems):
                        self.items = mediaItems
                    case let .failure(error):
                        Self.log.error("Spotify container fetch failed: \(error.localizedDescription, privacy: .public)")
                        self.items = []
                        self.errorMessage = "Couldn't load that: \(error.localizedDescription)"
                    }
                }
            }
            if id.hasPrefix("SPOTIFY:album:") {
                let spotifyID = String(id.dropFirst("SPOTIFY:album:".count))
                SpotifyAPI.albumTracks(id: spotifyID, auth: self.auth) { result in
                    completion(result.map { $0.items.map { self.mediaItem(from: $0) } })
                }
            } else if id.hasPrefix("SPOTIFY:playlist:") {
                let spotifyID = String(id.dropFirst("SPOTIFY:playlist:".count))
                SpotifyAPI.playlistItems(id: spotifyID, auth: self.auth) { result in
                    completion(result.map { $0.items.compactMap(\.item).map { self.mediaItem(from: $0) } })
                }
            } else if id.hasPrefix("SPOTIFY:artist:") {
                let spotifyID = String(id.dropFirst("SPOTIFY:artist:".count))
                SpotifyAPI.artistAlbums(id: spotifyID, auth: self.auth) { result in
                    completion(result.map { page in
                        page.items
                            .sorted { SpotifyReleaseDate.sortKey($0.release_date ?? "") > SpotifyReleaseDate.sortKey($1.release_date ?? "") }
                            .map { self.mediaItem(from: $0) }
                    })
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

    /// Fetched once per app launch, same caching shape as `withCredentials`. Runs `then` either
    /// way - a failed lookup just means every playlist filters out as unlistable rather than
    /// blocking browsing entirely.
    private func withUserID(then: @escaping () -> Void) {
        guard !didAttemptUserIDFetch, userID == nil else {
            then()
            return
        }
        SpotifyAPI.me(auth: auth) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                if case let .success(user) = result {
                    self.userID = user.id
                }
                self.didAttemptUserIDFetch = true
                then()
            }
        }
    }

    /// Development Mode's `/playlists/{id}/items` 403s for any playlist the user neither owns
    /// nor collaborates on (see `Playlist.collaborative`'s doc comment) - filtered out here
    /// rather than left to fail when opened.
    private func isListable(_ playlist: SpotifyModels.Playlist) -> Bool {
        playlist.collaborative || (userID != nil && playlist.owner?.id == userID)
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
        let playlists = (response.playlists?.items ?? []).compactMap { $0 }.filter(isListable).map { mediaItem(from: $0) }
        return tracks + albums + playlists
    }

    private func mediaItem(from track: SpotifyModels.Track, category: MediaItem.Category = .track) -> MediaItem {
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
            canExpand: false,
            category: category
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
            releaseDate: album.release_date,
            category: .album
        )
    }

    private func mediaItem(from playlist: SpotifyModels.Playlist) -> MediaItem {
        MediaItem(
            id: "SPOTIFY:playlist:\(playlist.id)",
            title: playlist.name,
            subtitle: playlist.owner?.display_name,
            artURL: playlist.images?.first.flatMap { URL(string: $0.url) },
            isContainer: true,
            canExpand: true,
            category: .playlist
        )
    }

    /// No `playURI`: there's no artist-level Sonos URI (see `SpotifyURIBuilder`'s doc comment),
    /// so an artist row is a container the user can open into their albums, never play directly.
    private func mediaItem(from artist: SpotifyModels.Artist, category: MediaItem.Category) -> MediaItem {
        MediaItem(
            id: "SPOTIFY:artist:\(artist.id)",
            title: artist.name,
            artURL: artist.images?.first.flatMap { URL(string: $0.url) },
            isContainer: true,
            canExpand: true,
            category: category
        )
    }
}

extension SpotifySearchModel: MediaBrowsing {}
