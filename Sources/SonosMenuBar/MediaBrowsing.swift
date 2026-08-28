import Foundation

/// What `MediaListView` needs from whatever is behind it - `BrowseModel` for Sonos content,
/// `SpotifySearchModel` for a Spotify search. Named after the fact: `BrowseModel` already had
/// this exact shape, so this is a name for its existing surface, not a new design.
protocol MediaBrowsing: ObservableObject {
    var path: [BrowseModel.Level] { get }
    var items: [MediaItem]? { get }
    var isLoading: Bool { get }
    var errorMessage: String? { get set }
    var filter: String { get set }
    var visibleItems: [MediaItem] { get }

    func open(_ item: MediaItem)
    func pop(to index: Int)
    func play(_ item: MediaItem, intent: PlayIntent, coordinatorUUID: String?)
}
