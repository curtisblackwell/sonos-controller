import SwiftUI

/// Every browse list in the app: favorites, Sonos playlists and their tracks, the queue.
///
/// One view rather than one per page, because the rows are the same rows - a `MediaItem` from
/// a favorite and one from a queue track differ in what they contain, not in what you can do
/// with them.
struct MediaListView<Model: MediaBrowsing>: View {
    @ObservedObject var browse: Model
    @ObservedObject var topology: TopologyModel

    /// The queue is the one list whose contents the user can edit, so it gets removal actions
    /// the others have no meaning for. Both closures are nil for anything that isn't the queue
    /// - `BrowsePage` is the only caller that supplies them.
    var showsQueueEditing = false
    /// `false` inside an open Spotify album: the album header above the list already shows its
    /// art once, so repeating it on every row is redundant.
    var showsArtwork = true
    var searchPrompt = "Filter"
    /// `false` for Spotify search: the header owns that filter field now, so this page's own
    /// copy would be a second box bound to the same text.
    var showsFilterField = true
    /// Sections rows under "Songs"/"Albums"/"Playlists" headers instead of one flat list -
    /// meaningful only for Spotify search, whose rows carry a `category`. Sonos browse lists
    /// leave `category` `nil` on every row, which collapses back to the flat list either way.
    var groupsByCategory = false
    var onClearQueue: (() -> Void)?
    var onRemoveFromQueue: ((MediaItem) -> Void)?
    /// Set only by the grouped-category grid (Spotify search/home). Nil everywhere else, which
    /// is also what keeps every category section under `categoryPreviewLimit` from growing a
    /// "View All" link it has nowhere to send the user.
    var onViewAllCategory: ((MediaItem.Category) -> Void)?
    /// Spotify search fetches from the server rather than filtering what's already on screen,
    /// so it needs to know when the user is done typing rather than live-filtering on every
    /// keystroke. Nil for every Sonos page, which keeps `browse.filter`'s existing client-side
    /// behavior.
    var onFilterSubmit: (() -> Void)?
    /// Overrides the default "Save something to My Sonos…" copy for a page that isn't Sonos's
    /// own content - Spotify search has nothing to do with My Sonos.
    var emptyDescriptionOverride: String?

    /// Emptying the queue throws away something the user assembled by hand and Sonos offers no
    /// way back, so it is the one action here that asks first.
    @State private var isConfirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            if hasHeaderContent {
                header
                Divider()
            }
            content
        }
        .confirmationDialog(
            "Remove every track from the queue?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear Queue", role: .destructive) { onClearQueue?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }

    // MARK: - Header

    /// Whether the header row has anything in it to show. Spotify search at its root has no
    /// breadcrumb (nothing to go back to), no queue button, and no filter field of its own -
    /// without this check, the header and its divider would still render as an empty bar with
    /// a stray line under it.
    private var hasHeaderContent: Bool {
        browse.path.count > 1
            || (showsQueueEditing && browse.items?.isEmpty == false)
            || showsFilterField
    }

    private var header: some View {
        HStack(spacing: 8) {
            breadcrumb
            Spacer(minLength: 12)
            if showsQueueEditing, browse.items?.isEmpty == false {
                Button("Clear Queue") { isConfirmingClear = true }
                    .controlSize(.small)
            }
            if showsFilterField {
                filterField
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Only shown once there is somewhere to go back to - a one-level path is just the page
    /// title, which the window already shows.
    @ViewBuilder
    private var breadcrumb: some View {
        if browse.path.count > 1 {
            HStack(spacing: 4) {
                ForEach(Array(browse.path.enumerated()), id: \.element.id) { index, level in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Button(level.title) { browse.pop(to: index) }
                        .buttonStyle(.plain)
                        .foregroundStyle(index == browse.path.count - 1 ? .primary : Color.accentColor)
                        .disabled(index == browse.path.count - 1)
                }
            }
            .lineLimit(1)
        }
    }

    private var filterField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(searchPrompt, text: $browse.filter)
                .textFieldStyle(.plain)
                .frame(width: 180)
                .onSubmit { onFilterSubmit?() }
            if !browse.filter.isEmpty {
                Button {
                    browse.filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch browse.items {
        case nil:
            // Distinct from an empty list: nothing has been read yet.
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .some(let items) where items.isEmpty:
            ContentUnavailableView {
                Label("Nothing Here", systemImage: "music.note.list")
            } description: {
                Text(emptyDescription)
            }
        default:
            // The queue is the one list the user reorders and removes from by row, so it keeps
            // the dense list layout. Everything else that's containers - albums, playlists,
            // artists - browses better as artwork tiles; a list of tracks (an opened album's or
            // playlist's songs, "Songs" in a search) reads better as rows than as a wall of
            // identical note icons, except top tracks, which stay tiled alongside the other home
            // categories.
            if showsQueueEditing || (!groupsByCategory && showsAsRows(browse.visibleItems)) {
                list
            } else {
                grid
            }
        }
    }

    /// Whether a homogeneous batch of items reads better as list rows than grid tiles: true for
    /// actual tracks, false for anything the user browses into (and for top tracks, which stay
    /// tiled with the rest of the home page).
    private func showsAsRows(_ items: [MediaItem]) -> Bool {
        guard let first = items.first else { return false }
        return first.category != .topTrack && !first.isContainer
    }

    private var emptyDescription: String {
        if let emptyDescriptionOverride { return emptyDescriptionOverride }
        if showsQueueEditing {
            return "The queue is empty. Play something to fill it."
        }
        return "Save something to My Sonos in the Sonos app and it will show up here."
    }

    private var list: some View {
        List {
            if groupsByCategory {
                ForEach(groupedByCategory, id: \.0) { category, items in
                    Section(category.title) {
                        ForEach(items) { item in row(item) }
                    }
                }
            } else {
                ForEach(browse.visibleItems) { item in
                    row(item)
                }
            }
            if browse.visibleItems.isEmpty {
                Text("Nothing matches “\(browse.filter)”.")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
        .overlay(alignment: .top) {
            if browse.isLoading {
                ProgressView().controlSize(.small).padding(6)
            }
        }
    }

    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 20), count: 5)
    /// How many items a grouped-category section shows before handing the rest off to "View
    /// All" - keeps Spotify home/search from stacking dozens of tiles per category on one page.
    private let categoryPreviewLimit = 10

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if groupsByCategory {
                    ForEach(groupedByCategory, id: \.0) { category, items in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(category.title).font(.headline)
                                Spacer()
                                if items.count > categoryPreviewLimit, let onViewAllCategory {
                                    Button("View All") { onViewAllCategory(category) }
                                        .buttonStyle(.plain)
                                        .font(.subheadline)
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            let capped = Array(items.prefix(categoryPreviewLimit))
                            if showsAsRows(items) {
                                rowsSection(capped)
                            } else {
                                gridSection(capped)
                            }
                        }
                    }
                } else {
                    gridSection(browse.visibleItems)
                }
                if browse.visibleItems.isEmpty {
                    Text("Nothing matches “\(browse.filter)”.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
        .overlay(alignment: .top) {
            if browse.isLoading {
                ProgressView().controlSize(.small).padding(6)
            }
        }
    }

    /// The "Songs" category section rendered as plain rows rather than tiles - reuses the same
    /// `row(_:)` a `List` would, just laid out in a `VStack` since it sits inside the grid
    /// page's `ScrollView` alongside tiled sections rather than owning the whole page.
    private func rowsSection(_ items: [MediaItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                row(item)
                    .padding(.vertical, 4)
                if item.id != items.last?.id {
                    Divider()
                }
            }
        }
    }

    private func gridSection(_ items: [MediaItem]) -> some View {
        LazyVGrid(columns: gridColumns, spacing: 16) {
            ForEach(items) { item in gridCell(item) }
        }
    }

    private func gridCell(_ item: MediaItem) -> some View {
        VStack(spacing: 6) {
            gridArtwork(item)
            VStack(spacing: 1) {
                Text(item.displayTitle)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .onTapGesture(count: 2) { activate(item) }
        .contextMenu { menu(for: item) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func gridArtwork(_ item: MediaItem) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.quaternary)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let url = item.artURL {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        placeholderIcon(item)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    placeholderIcon(item)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topTrailing) {
                if item.canExpand {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.white, .black.opacity(0.5))
                        .padding(4)
                }
            }
    }

    /// Rows bucketed by `category` in `MediaItem.Category`'s fixed order (songs, then albums,
    /// then playlists) rather than a `Dictionary` grouping, which wouldn't preserve that order.
    /// A row with no category (every non-Spotify-search list) falls out of every bucket, so this
    /// is only ever non-empty when `groupsByCategory` is set.
    private var groupedByCategory: [(MediaItem.Category, [MediaItem])] {
        let items = browse.visibleItems
        return MediaItem.Category.allCases.compactMap { category in
            let matches = items.filter { $0.category == category }
            return matches.isEmpty ? nil : (category, matches)
        }
    }

    private func row(_ item: MediaItem) -> some View {
        HStack(spacing: 10) {
            if showsArtwork {
                artwork(item)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayTitle).lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let album = item.album {
                    Text(album)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if item.canExpand {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(.rect)
        // Opening beats playing when both are possible: a Sonos playlist you clicked into can
        // still be played from its own row's menu, but a playlist played by accident has
        // already replaced what was on.
        .onTapGesture(count: 2) { activate(item) }
        .contextMenu { menu(for: item) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func artwork(_ item: MediaItem) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(.quaternary)
            .frame(width: 36, height: 36)
            .overlay {
                if let url = item.artURL {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        placeholderIcon(item)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                } else {
                    placeholderIcon(item)
                }
            }
    }

    private func placeholderIcon(_ item: MediaItem) -> some View {
        Image(systemName: item.isContainer ? "music.note.list" : "music.note")
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func menu(for item: MediaItem) -> some View {
        if item.canExpand {
            Button("Open") { browse.open(item) }
        }
        if item.isPlayable {
            Button("Play") { play(item, .now) }
            // Withheld for a row that is already in the queue: both would enqueue a second
            // copy of a track the user is looking at in the queue, which reads as a bug.
            if item.queuePosition == nil {
                Button("Play Next") { play(item, .next) }
                Button("Add to Queue") { play(item, .last) }
            }
        }
        if item.queuePosition != nil {
            Divider()
            Button("Remove from Queue") { onRemoveFromQueue?(item) }
        }
    }

    private func activate(_ item: MediaItem) {
        if item.canExpand {
            browse.open(item)
        } else {
            play(item, .now)
        }
    }

    private func play(_ item: MediaItem, _ intent: PlayIntent) {
        browse.play(item, intent: intent, coordinatorUUID: topology.activeGroupID)
    }
}
