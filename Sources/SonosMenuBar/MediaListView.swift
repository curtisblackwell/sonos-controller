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
    var searchPrompt = "Filter"
    var onClearQueue: (() -> Void)?
    var onRemoveFromQueue: ((MediaItem) -> Void)?
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
            header
            Divider()
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

    private var header: some View {
        HStack(spacing: 8) {
            breadcrumb
            Spacer(minLength: 12)
            if showsQueueEditing, browse.items?.isEmpty == false {
                Button("Clear Queue") { isConfirmingClear = true }
                    .controlSize(.small)
            }
            filterField
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
            list
        }
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
            ForEach(browse.visibleItems) { item in
                row(item)
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

    private func row(_ item: MediaItem) -> some View {
        HStack(spacing: 10) {
            artwork(item)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayTitle).lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
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
