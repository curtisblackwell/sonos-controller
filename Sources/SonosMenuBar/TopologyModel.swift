import Foundation
import Combine

/// Where a room should end up when it is moved in the editor.
enum GroupDestination: Equatable {
    case group(coordinatorUUID: String)
    case standalone
}

/// The state behind the grouping editor. Owns the grouping commands and the local
/// optimistic view of the topology; the app delegate feeds it fresh topology and provides
/// the refresh action, so this type stays free of discovery and AppKit.
final class TopologyModel: ObservableObject {
    @Published private(set) var groups: [SonosGroup] = []
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    /// The group the media keys drive. Mirrored into `PreferencesStore`.
    @Published private(set) var activeGroupID: String?

    /// Set by the app delegate to trigger a topology refetch.
    var refreshHandler: (() -> Void)?
    /// The status menu shows the same selection, so it needs to know when it changes here.
    var onActiveGroupChanged: (() -> Void)?

    private let grouping = SonosGrouping()

    init() {
        activeGroupID = PreferencesStore.activeGroupID
        grouping.onDidSettle = { [weak self] in
            self?.isBusy = false
            self?.refreshHandler?()
        }
        // Deliberately does not clear isBusy: a failure of one queued command doesn't mean
        // the ones behind it have finished. onDidSettle is the only thing that ends the
        // busy state, and it fires whether the commands succeeded or not.
        grouping.onError = { [weak self] message in
            self?.errorMessage = message
        }
    }

    // MARK: - Input from the app

    func update(groups: [SonosGroup]) {
        self.groups = groups
        // The app delegate reconciles the saved selection against the fresh topology before
        // handing it over, so PreferencesStore is the authority - re-read it rather than
        // only ever clearing. Clearing alone meant one empty fetch dropped the editor's
        // star for the rest of the session while the status menu kept its checkmark.
        let resolved = PreferencesStore.activeGroupID
        guard resolved != activeGroupID else { return }
        activeGroupID = resolved
        onActiveGroupChanged?()
    }

    var allRooms: [SonosRoom] { SonosTopology.allRooms(in: groups) }

    /// Matched on UUID alone: a room dragged from the list carries the name and IP it had
    /// when the drag started, and a refresh in between would make full equality miss.
    func group(containing room: SonosRoom) -> SonosGroup? {
        groups.first { $0.members.contains { $0.uuid == room.uuid } }
    }

    // MARK: - Actions

    /// The single place that decides whether a move is worth sending. Every early return
    /// here happens before `isBusy` is set, so the spinner can't latch on a no-op.
    func move(room: SonosRoom, to destination: GroupDestination) {
        guard let current = group(containing: room) else { return }

        switch destination {
        case let .group(coordinatorUUID):
            // Can't join itself, and can't join the group it is already in.
            guard room.uuid != coordinatorUUID, current.id != coordinatorUUID else { return }
            isBusy = true
            grouping.join(room: room, coordinatorUUID: coordinatorUUID)

        case .standalone:
            guard !current.isStandalone else { return }
            isBusy = true
            if current.id == room.uuid, let successor = current.members.first(where: { $0.uuid != room.uuid }) {
                // Removing the coordinator: the group has to be handed to another member
                // first, or the command is a no-op and the room silently stays put.
                grouping.handOffCoordination(from: room, to: successor.uuid)
            } else {
                grouping.makeStandalone(room: room)
            }
        }
    }

    func setActiveGroup(_ group: SonosGroup) {
        PreferencesStore.setActiveGroup(group)
        activeGroupID = group.id
        onActiveGroupChanged?()
    }

    func refresh() {
        refreshHandler?()
    }
}
