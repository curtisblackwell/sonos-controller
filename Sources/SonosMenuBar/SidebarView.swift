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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speakers: return "Speakers"
        case .queue: return "Queue"
        case .favorites: return "My Sonos"
        case .playlists: return "Sonos Playlists"
        }
    }

    var systemImage: String {
        switch self {
        case .speakers: return "hifispeaker.and.homepod"
        case .queue: return "list.triangle"
        case .favorites: return "star"
        case .playlists: return "music.note.list"
        }
    }

    /// The ObjectID this page browses, or nil for a page that isn't a browse list.
    var browseRoot: BrowseModel.Level? {
        switch self {
        case .speakers:
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
            Section("System") {
                row(.speakers)
                row(.queue)
            }
            Section("Library") {
                row(.favorites)
                row(.playlists)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 300)
    }

    private func row(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.systemImage).tag(item)
    }
}
