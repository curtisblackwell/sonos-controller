import AppKit
import Foundation
import CryptoKit
import os.log

/// Authorization Code + PKCE against Spotify's own accounts service. A desktop app is a
/// public client - it cannot hold a client secret - so PKCE is what proves the token exchange
/// came from whoever made the original authorize request, via the code verifier rather than a
/// secret.
///
/// Scoped to browsing only (`playlist-read-private playlist-read-collaborative
/// user-library-read user-top-read user-follow-read`): this app never plays anything through
/// Spotify itself, Sonos does, so there is nothing here that needs a playback scope.
final class SpotifyAuth: ObservableObject {
    private static let log = Logger(subsystem: "com.curtisblackwell.sonos-controller", category: "spotify-auth")
    private static let scopes =
        "playlist-read-private playlist-read-collaborative user-library-read user-top-read user-follow-read"

    private enum KeychainKey {
        static let accessToken = "accessToken"
        static let refreshToken = "refreshToken"
        static let expiresAt = "expiresAt"
    }

    @Published private(set) var isAuthenticated: Bool

    /// The verifier for the authorize request currently in flight, and the `state` it was sent
    /// with. Both are needed again when the redirect lands, and neither is sensitive enough to
    /// need the Keychain - the whole round trip happens within one browser hop.
    private var pendingVerifier: String?
    private var pendingState: String?

    init() {
        isAuthenticated = SpotifyKeychain.get(KeychainKey.refreshToken) != nil
    }

    // MARK: - Login

    func startLogin() {
        guard let clientID = SpotifyConfig.clientID, !clientID.isEmpty else {
            Self.log.error("No SpotifyClientID configured - see Info.plist")
            return
        }
        let verifier = Self.randomVerifier()
        let state = Self.randomVerifier()
        pendingVerifier = verifier
        pendingState = state

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: SpotifyConfig.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: verifier)),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Called from `AppDelegate` when the redirect URI is opened. Not on the main thread's
    /// dime for the network part - the token exchange completes asynchronously.
    func handleRedirect(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let verifier = pendingVerifier
        else { return }
        let query = components.queryItems ?? []
        let returnedState = query.first { $0.name == "state" }?.value
        guard returnedState != nil, returnedState == pendingState else {
            Self.log.error("Spotify redirect state mismatch, dropping it")
            return
        }
        pendingVerifier = nil
        pendingState = nil

        guard let code = query.first(where: { $0.name == "code" })?.value else {
            let error = query.first { $0.name == "error" }?.value ?? "unknown"
            Self.log.error("Spotify authorize returned no code: \(error, privacy: .public)")
            return
        }

        exchangeCodeForToken(code: code, verifier: verifier)
    }

    func signOut() {
        SpotifyKeychain.remove(KeychainKey.accessToken)
        SpotifyKeychain.remove(KeychainKey.refreshToken)
        SpotifyKeychain.remove(KeychainKey.expiresAt)
        DispatchQueue.main.async { [weak self] in
            self?.isAuthenticated = false
        }
    }

    // MARK: - Token access

    /// The current access token, refreshing first if it has expired (or is about to). Runs
    /// the completion on whatever queue the underlying request lands on.
    func validAccessToken(completion: @escaping (String?) -> Void) {
        guard let refreshToken = SpotifyKeychain.get(KeychainKey.refreshToken) else {
            completion(nil)
            return
        }
        if let token = SpotifyKeychain.get(KeychainKey.accessToken),
           let expiresAt = SpotifyKeychain.get(KeychainKey.expiresAt).flatMap(TimeInterval.init),
           !Self.isExpired(expiresAt: expiresAt) {
            completion(token)
            return
        }
        refresh(refreshToken: refreshToken, completion: completion)
    }

    /// A 60s cushion so a token that is about to expire gets refreshed rather than handed out
    /// and expiring mid-request.
    static func isExpired(expiresAt: TimeInterval, now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        now >= expiresAt - 60
    }

    private func refresh(refreshToken: String, completion: @escaping (String?) -> Void) {
        guard let clientID = SpotifyConfig.clientID else {
            completion(nil)
            return
        }
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self, let data, error == nil,
                  let token = Self.storeTokenResponse(data, fallbackRefreshToken: refreshToken)
            else {
                Self.log.error("Spotify token refresh failed: \(error?.localizedDescription ?? "bad response", privacy: .public)")
                completion(nil)
                return
            }
            DispatchQueue.main.async { self.isAuthenticated = true }
            completion(token)
        }.resume()
    }

    private func exchangeCodeForToken(code: String, verifier: String) {
        guard let clientID = SpotifyConfig.clientID else { return }
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": SpotifyConfig.redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self, let data, error == nil,
                  Self.storeTokenResponse(data, fallbackRefreshToken: nil) != nil
            else {
                Self.log.error("Spotify token exchange failed: \(error?.localizedDescription ?? "bad response", privacy: .public)")
                return
            }
            DispatchQueue.main.async { self.isAuthenticated = true }
        }.resume()
    }

    /// Parses a token response and writes it to the Keychain. Spotify only returns
    /// `refresh_token` on the very first exchange, not on every refresh, so a refresh keeps the
    /// one already stored unless a new one is given.
    @discardableResult
    private static func storeTokenResponse(_ data: Data, fallbackRefreshToken: String?) -> String? {
        struct TokenResponse: Decodable {
            let access_token: String
            let expires_in: Int
            let refresh_token: String?
        }
        guard let response = try? JSONDecoder().decode(TokenResponse.self, from: data) else { return nil }
        SpotifyKeychain.set(response.access_token, forKey: KeychainKey.accessToken)
        SpotifyKeychain.set(
            String(Date().timeIntervalSince1970 + Double(response.expires_in)),
            forKey: KeychainKey.expiresAt
        )
        if let refreshToken = response.refresh_token ?? fallbackRefreshToken {
            SpotifyKeychain.set(refreshToken, forKey: KeychainKey.refreshToken)
        }
        return response.access_token
    }

    private static func formBody(_ parameters: [String: String]) -> Data {
        let encoded = parameters
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? "")" }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }

    // MARK: - PKCE

    static func randomVerifier(length: Int = 64) -> String {
        let allowed = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).compactMap { _ in allowed.randomElement() })
    }

    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension CharacterSet {
    /// `URLQueryItem` handles encoding for GET requests, but a POST body built by hand needs
    /// its own - `.urlQueryAllowed` alone still leaves `+` and `&` unescaped inside a value.
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
