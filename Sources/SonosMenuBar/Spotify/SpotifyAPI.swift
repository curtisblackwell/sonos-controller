import Foundation
import os.log

enum SpotifyAPIError: LocalizedError {
    case notAuthenticated
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not connected to Spotify."
        case let .httpStatus(code): return "Spotify returned HTTP \(code)."
        }
    }
}

/// Read-only access to the pieces of Spotify's Web API this app browses: search, the user's
/// own playlists and saved albums, and the tracks inside one. Takes a `SpotifyAuth` rather than
/// reaching for a shared instance, the same way `SonosSOAP.send` takes the IP to talk to rather
/// than assuming a single household.
enum SpotifyAPI {
    private static let log = Logger(subsystem: "com.curtisblackwell.sonos-controller", category: "spotify-api")
    private static let base = "https://api.spotify.com/v1"

    static func search(
        query: String,
        auth: SpotifyAuth,
        completion: @escaping (Result<SpotifyModels.SearchResponse, Error>) -> Void
    ) {
        var components = URLComponents(string: "\(base)/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "track,album,playlist"),
            // Search's own max, cut from 50 to 10 in Spotify's February 2026 changelog -
            // distinct from the 50 the other endpoints here still allow.
            URLQueryItem(name: "limit", value: "10"),
        ]
        get(components.url!, auth: auth, completion: completion)
    }

    static func myPlaylists(
        auth: SpotifyAuth,
        completion: @escaping (Result<SpotifyModels.Paging<SpotifyModels.Playlist>, Error>) -> Void
    ) {
        get(URL(string: "\(base)/me/playlists?limit=50")!, auth: auth, completion: completion)
    }

    static func myAlbums(
        auth: SpotifyAuth,
        completion: @escaping (Result<SpotifyModels.Paging<SpotifyModels.SavedAlbumItem>, Error>) -> Void
    ) {
        get(URL(string: "\(base)/me/albums?limit=50")!, auth: auth, completion: completion)
    }

    static func playlistItems(
        id: String,
        auth: SpotifyAuth,
        completion: @escaping (Result<SpotifyModels.Paging<SpotifyModels.PlaylistTrackItem>, Error>) -> Void
    ) {
        get(URL(string: "\(base)/playlists/\(id)/tracks?limit=50")!, auth: auth, completion: completion)
    }

    static func albumTracks(
        id: String,
        auth: SpotifyAuth,
        completion: @escaping (Result<SpotifyModels.Paging<SpotifyModels.Track>, Error>) -> Void
    ) {
        get(URL(string: "\(base)/albums/\(id)/tracks?limit=50")!, auth: auth, completion: completion)
    }

    /// Seconds to wait before retrying a 429. Spotify always sends `Retry-After`, but a missing
    /// or unparseable one still needs a delay rather than hammering the endpoint immediately.
    static func retryDelay(retryAfterHeader: String?) -> TimeInterval {
        retryAfterHeader.flatMap(Double.init) ?? 1
    }

    // MARK: - Transport

    /// One retry on HTTP 429, after the delay the `Retry-After` header names - anything past
    /// that and the failure is surfaced rather than silently retried again.
    private static func get<T: Decodable>(
        _ url: URL,
        auth: SpotifyAuth,
        allowRetry: Bool = true,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        auth.validAccessToken { token in
            guard let token else {
                completion(.failure(SpotifyAPIError.notAuthenticated))
                return
            }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    completion(.failure(SpotifyAPIError.httpStatus(0)))
                    return
                }
                if http.statusCode == 429, allowRetry {
                    let retryAfter = retryDelay(retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"))
                    log.notice("Spotify rate limited, retrying in \(retryAfter, privacy: .public)s")
                    DispatchQueue.global().asyncAfter(deadline: .now() + retryAfter) {
                        get(url, auth: auth, allowRetry: false, completion: completion)
                    }
                    return
                }
                guard http.statusCode == 200, let data else {
                    if let data, let body = String(data: data, encoding: .utf8) {
                        log.error("Spotify \(url.path, privacy: .public) returned HTTP \(http.statusCode): \(body, privacy: .public)")
                    }
                    completion(.failure(SpotifyAPIError.httpStatus(http.statusCode)))
                    return
                }
                do {
                    completion(.success(try JSONDecoder().decode(T.self, from: data)))
                } catch {
                    log.error("Spotify decode failed for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    completion(.failure(error))
                }
            }.resume()
        }
    }
}
