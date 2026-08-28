import SwiftUI

/// The Spotify sidebar page: a connect prompt until authenticated, then the same list view
/// every Sonos browse page uses, bound to a `SpotifySearchModel` instead of a `BrowseModel`.
struct SpotifySearchPage: View {
    @ObservedObject var model: SpotifySearchModel
    /// Observed separately from `model`: `SpotifyAuth`'s `isAuthenticated` publishes through its
    /// own `objectWillChange`, not through `model`'s, so the connect prompt needs its own watch
    /// on it to update when a login completes.
    @ObservedObject var auth: SpotifyAuth
    @ObservedObject var topology: TopologyModel

    var body: some View {
        Group {
            if auth.isAuthenticated {
                MediaListView(
                    browse: model,
                    topology: topology,
                    searchPrompt: "Search Spotify",
                    onFilterSubmit: { model.search() },
                    emptyDescriptionOverride: "Search for a track, album, or playlist above, then press Return."
                )
            } else {
                connectPrompt
            }
        }
        .alert(
            "Couldn't Load",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            presenting: model.errorMessage
        ) { _ in
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    private var connectPrompt: some View {
        ContentUnavailableView {
            Label("Connect Spotify", systemImage: "music.note")
        } description: {
            Text("Sign in to search your Spotify library and play tracks on your Sonos system.")
        } actions: {
            Button("Connect to Spotify") { auth.startLogin() }
        }
    }
}
