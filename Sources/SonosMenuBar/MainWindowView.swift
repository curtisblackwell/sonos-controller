import SwiftUI

/// The window: a sidebar of pages, the selected page, and a now-playing bar across the
/// bottom of both.
///
/// The bar is deliberately outside the split view. It reports on the active group, which
/// doesn't change when you switch pages, so nesting it in the detail column would make it
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
            NavigationSplitView {
                SidebarView(selection: $selection)
            } detail: {
                detail
            }
            Divider()
            NowPlayingBar(model: model, volume: volume, playback: playback)
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
        Group {
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
        .navigationTitle(item.title)
    }
}
