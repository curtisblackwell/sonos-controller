import Foundation

/// Spotify app credentials. Read from Info.plist rather than hardcoded, so an open-source
/// build never ships with a client id baked into source - see the build's xcconfig for how
/// `SPOTIFY_CLIENT_ID` reaches the plist.
enum SpotifyConfig {
    static let redirectURI = "sonos-controller://spotify-auth-callback"

    static var clientID: String? {
        Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String
    }
}
