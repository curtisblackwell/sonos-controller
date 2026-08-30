import SwiftUI

/// The window: a header bar, a sidebar of pages, the selected page, and a now-playing bar
/// across the bottom of both.
///
/// Both bars are deliberately outside the split view. They report on the active group, which
/// doesn't change when you switch pages, so nesting them in the detail column would make them
/// look like a property of whatever page you happened to be on.
struct MainWindowView: View {
    @ObservedObject var model: TopologyModel
    @ObservedObject var volume: VolumeModel
    @ObservedObject var playback: PlaybackModel
    @ObservedObject var browse: BrowseModel
    @ObservedObject var spotifySearch: SpotifySearchModel
    @ObservedObject var spotifyAuth: SpotifyAuth

    static let minWindowWidth: CGFloat = 960

    /// Optional because that is the shape `List(selection:)` wants for a single selection;
    /// `detail` falls back to `.speakers` rather than showing an empty column, since there
    /// is no state in which no page should be shown.
    @State private var selection: SidebarItem? = PreferencesStore.selectedSidebarItem

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(
                model: model,
                volume: volume,
                playback: playback,
                spotifySearch: spotifySearch,
                spotifyAuth: spotifyAuth,
                selection: $selection
            )
            Divider()
            HStack(spacing: 0) {
                SidebarView(selection: $selection, spotifyAuth: spotifyAuth)
                    .frame(width: 200)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            NowPlayingBar(model: model, playback: playback)
        }
        .frame(minWidth: Self.minWindowWidth, minHeight: 420)
        .onChange(of: selection) { _, newSelection in
            guard let newSelection else { return }
            PreferencesStore.selectedSidebarItem = newSelection
        }
    }

    @ViewBuilder
    private var detail: some View {
        let item = selection ?? .speakers
        if let root = item.browseRoot {
            BrowsePage(
                browse: browse,
                topology: model,
                root: root,
                showsQueueEditing: item == .queue,
                searchPrompt: "Filter \(item.title)"
            )
        } else if item == .spotify {
            SpotifySearchPage(model: spotifySearch, auth: spotifyAuth, topology: model)
        } else {
            SpeakersPage(model: model, volume: volume)
        }
    }
}
