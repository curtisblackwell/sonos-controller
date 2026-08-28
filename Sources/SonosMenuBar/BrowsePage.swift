import SwiftUI

/// A browse list rooted at one ObjectID.
///
/// One view covers favorites, Sonos playlists, and the queue rather than three near-identical
/// pages: they differ only in where they start and whether the queue's editing actions apply.
struct BrowsePage: View {
    @ObservedObject var browse: BrowseModel
    @ObservedObject var topology: TopologyModel

    let root: BrowseModel.Level
    var showsQueueEditing = false
    var searchPrompt = "Filter"

    var body: some View {
        MediaListView(
            browse: browse,
            topology: topology,
            showsQueueEditing: showsQueueEditing,
            searchPrompt: searchPrompt,
            onClearQueue: { browse.clearQueue() },
            onRemoveFromQueue: { browse.removeFromQueue($0) }
        )
        // The model is shared across pages, so it has to be pointed at this page's root both
        // on first appearance and whenever the sidebar switches to a different one. `show` is
        // a no-op when the root is already open, so this doesn't refetch on every redraw.
        .onAppear { browse.show(root: root) }
        .onChange(of: root) { _, newRoot in browse.show(root: newRoot) }
        .alert(
            "Couldn't Load",
            isPresented: Binding(
                get: { browse.errorMessage != nil },
                set: { if !$0 { browse.errorMessage = nil } }
            ),
            presenting: browse.errorMessage
        ) { _ in
            Button("OK", role: .cancel) { browse.errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }
}
