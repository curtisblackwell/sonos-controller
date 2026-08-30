import SwiftUI

/// One row in the sidebar, and one page in the detail column.
///
/// Raw values are persisted in `PreferencesStore`, so they are part of the app's stored
/// state - renaming a case silently drops the user back to the default page.
enum SidebarItem: String, CaseIterable, Identifiable {
    case speakers
    case queue
    case favorites
    case playlists
    case spotify

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speakers: return "Speakers"
        case .queue: return "Queue"
        case .favorites: return "My Sonos"
        case .playlists: return "Sonos Playlists"
        case .spotify: return "Spotify"
        }
    }

    var systemImage: String {
        switch self {
        case .speakers: return "hifispeaker.and.homepod"
        case .queue: return "list.triangle"
        case .favorites: return "star"
        case .playlists: return "music.note.list"
        case .spotify: return "music.note"
        }
    }

    /// The ObjectID this page browses, or nil for a page that isn't a Sonos browse list -
    /// Spotify search is answered by Spotify's own API, not a Sonos player.
    var browseRoot: BrowseModel.Level? {
        switch self {
        case .speakers, .spotify:
            return nil
        case .queue:
            return BrowseModel.Level(objectID: SonosContentDirectory.ObjectID.queue, title: title)
        case .favorites:
            return BrowseModel.Level(objectID: SonosContentDirectory.ObjectID.favorites, title: title)
        case .playlists:
            return BrowseModel.Level(objectID: SonosContentDirectory.ObjectID.sonosPlaylists, title: title)
        }
    }
}

struct SidebarView: View {
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                row(.spotify)
                row(.favorites)
                row(.playlists)
            }
            Section("System") {
                row(.speakers)
                row(.queue)
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.systemImage).tag(item)
    }
}
