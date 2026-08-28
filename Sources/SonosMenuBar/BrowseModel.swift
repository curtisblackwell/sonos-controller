import Foundation
import os.log

/// The state behind every browse list: favorites, Sonos playlists, the queue.
///
/// Main thread only. `SonosContentDirectory`'s completions land on a URLSession queue, so
/// everything here hops back before touching published state - the same arrangement as
/// `PlaybackModel`, including the `generation` counter that keeps a slow response from landing
/// after the user has already navigated somewhere else.
final class BrowseModel: ObservableObject {
    private static let log = Logger(subsystem: "com.curtisblackwell.sonos-controller", category: "browse-model")

    /// One rung of the browse path. Sonos playlists open into their tracks, so a list is not
    /// always the top of its own hierarchy.
    struct Level: Equatable, Identifiable {
        let objectID: String
        let title: String
        var id: String { objectID }
    }

    @Published private(set) var path: [Level] = []
    /// nil until a load for the current level has landed - so an empty list can be told from
    /// one that hasn't arrived, and "No items" isn't shown over a request in flight.
    @Published private(set) var items: [MediaItem]?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    /// Client-side, because there is no server-side search: Sonos does not implement the UPnP
    /// `Search` action, so filtering what we already fetched is the only search available.
    @Published var filter = ""

    private var coordinatorIP: String?
    private var generation = 0

    var currentLevel: Level? { path.last }

    var visibleItems: [MediaItem] {
        guard let items else { return [] }
        let term = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return items }
        return items.filter { item in
            item.title.localizedCaseInsensitiveContains(term)
                || item.subtitle?.localizedCaseInsensitiveContains(term) == true
        }
    }

    // MARK: - Topology

    /// Called with the active group's coordinator IP whenever it might have changed. Browse is
    /// answered by any player, but it has to be one that exists - and the queue in particular
    /// belongs to the coordinator, so reading it from anywhere else would show the wrong list.
    func update(coordinatorIP: String?) {
        guard coordinatorIP != self.coordinatorIP else { return }
        self.coordinatorIP = coordinatorIP
        generation += 1
        items = nil
        if currentLevel != nil { load() }
    }

    // MARK: - Navigation

    /// Points the model at a top-level list, discarding any path already open. Idempotent, so
    /// a view can call it on every appearance without refetching.
    func show(root: Level) {
        guard path != [root] else { return }
        path = [root]
        filter = ""
        load()
    }

    /// Opens a container. Refuses anything the player won't enumerate - a music service's own
    /// container is playable but not browsable, and asking for its children returns UPnP 701
    /// rather than a list.
    func open(_ item: MediaItem) {
        guard item.canExpand else { return }
        path.append(Level(objectID: item.id, title: item.displayTitle))
        filter = ""
        load()
    }

    /// Drops back to `index` in the path. Out-of-range is ignored rather than trapping: the
    /// breadcrumb is rebuilt from `path`, but a tap can still arrive after a reset.
    func pop(to index: Int) {
        guard index >= 0, index < path.count, index != path.count - 1 else { return }
        path = Array(path.prefix(index + 1))
        filter = ""
        load()
    }

    func reload() {
        load()
    }

    private func load() {
        guard let level = currentLevel else { return }
        guard let ip = coordinatorIP else {
            // Not an error state: the household hasn't resolved yet, and the next
            // `update(coordinatorIP:)` will start this load.
            items = nil
            return
        }
        generation += 1
        let requestGeneration = generation
        isLoading = true
        SonosContentDirectory.browseAll(objectID: level.objectID, from: ip) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, requestGeneration == self.generation else { return }
                self.isLoading = false
                switch result {
                case let .success(items):
                    self.items = items
                case let .failure(error):
                    Self.log.error("Browse \(level.objectID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    self.items = []
                    self.errorMessage = "Couldn't read \(level.title): \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Playing

    /// Sends `item` to the active group. `coordinatorUUID` is needed as well as the IP because
    /// starting a queue means naming it, and a queue is named by its coordinator's UUID.
    func play(_ item: MediaItem, intent: PlayIntent, coordinatorUUID: String?) {
        guard let ip = coordinatorIP, let coordinatorUUID else {
            errorMessage = "Pick a group for the media keys first - that's where music plays."
            return
        }
        let commands = SonosQueue.commands(for: item, intent: intent, coordinatorUUID: coordinatorUUID)
        guard !commands.isEmpty else {
            errorMessage = "\(item.displayTitle) doesn't have anything to play."
            return
        }
        SonosQueue.perform(commands, coordinatorIP: ip) { [weak self] result in
            guard let self else { return }
            if case let .failure(error) = result {
                self.errorMessage = "Couldn't play \(item.displayTitle): \(error.localizedDescription)"
                return
            }
            // The queue list is the one view that shows the result of its own action, so it
            // has to re-read; every other list is unchanged by playing something.
            if self.currentLevel?.objectID.hasPrefix("Q:") == true { self.load() }
        }
    }

    /// Removes one track from the queue, then re-reads it.
    func removeFromQueue(_ item: MediaItem) {
        guard let ip = coordinatorIP, item.id.hasPrefix("Q:") else { return }
        SonosControl.send(action: .removeTrackFromQueue(objectID: item.id, updateID: 0), to: ip) { [weak self] _ in
            DispatchQueue.main.async { self?.load() }
        }
    }

    func clearQueue() {
        guard let ip = coordinatorIP else { return }
        SonosControl.send(action: .removeAllTracksFromQueue, to: ip) { [weak self] _ in
            DispatchQueue.main.async { self?.load() }
        }
    }
}
