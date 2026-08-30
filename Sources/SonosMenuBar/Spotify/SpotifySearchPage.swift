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
                Group {
                    if model.openContainer != nil {
                        HStack(alignment: .top, spacing: 16) {
                            containerHeader
                            Divider()
                            mediaList
                        }
                    } else {
                        mediaList
                    }
                }
                .onAppear { model.showHomeIfAtRoot() }
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

    /// Art, title, artist, and release date for whichever album or playlist is open, plus a
    /// button that plays it in full. Forms a fixed-width column to the left of the track list;
    /// nothing shown while browsing anything else.
    @ViewBuilder
    private var containerHeader: some View {
        if let container = model.openContainer {
            VStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(width: 240, height: 240)
                    .overlay {
                        if let url = container.artURL {
                            AsyncImage(url: url) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Image(systemName: "music.note").foregroundStyle(.secondary)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            Image(systemName: "music.note").foregroundStyle(.secondary)
                        }
                    }

                VStack(spacing: 2) {
                    Text(container.title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    if let artist = container.artist {
                        Text(artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let releaseDate = container.releaseDate {
                        Text(SpotifyReleaseDate.formatted(releaseDate))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if container.kind != .artist {
                    Button {
                        model.playContainer(coordinatorUUID: topology.activeGroupID)
                    } label: {
                        Label("Play \(container.noun)", systemImage: "play.fill")
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(width: 240)
            .padding(16)
        }
    }

    private var mediaList: some View {
        MediaListView(
            browse: model,
            topology: topology,
            // An artist's own header art doesn't stand in for its albums' art the way an open
            // album's or playlist's header does for its tracks - each album row still needs its
            // own artwork.
            showsArtwork: model.openContainer == nil || model.openContainer?.kind == .artist,
            showsFilterField: false,
            groupsByCategory: model.currentLevel?.objectID == "SPOTIFY:root",
            onViewAllCategory: { model.openCategory($0) },
            emptyDescriptionOverride: "Search for a track, album, or playlist above, then press Return."
        )
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
