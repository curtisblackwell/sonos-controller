import Foundation
import Combine

/// Where a room should end up when it is moved in the editor.
enum GroupDestination: Equatable {
    case group(coordinatorUUID: String)
    case standalone
}

/// One grouping call. A single move can need two of these, in order.
enum GroupingCommand: Equatable {
    case join(room: SonosRoom, coordinatorUUID: String)
    case handOffCoordination(room: SonosRoom, successorUUID: String)
    case makeStandalone(room: SonosRoom)
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

    func move(room: SonosRoom, to destination: GroupDestination) {
        // `groups` only catches up on the next discovery, roughly a second after the last
        // command settles. Deciding a second move against that stale picture picks the
        // wrong command - ungroup a coordinator, then immediately ungroup the member that
        // just inherited the group, and we'd send it BecomeCoordinatorOfStandaloneGroup,
        // which does nothing. Refuse to decide until the topology is real again.
        guard !isBusy else { return }

        let commands = Self.commands(moving: room, to: destination, in: groups)
        guard !commands.isEmpty else { return }

        isBusy = true
        for command in commands {
            switch command {
            case let .join(room, coordinatorUUID):
                grouping.join(room: room, coordinatorUUID: coordinatorUUID)
            case let .handOffCoordination(room, successorUUID):
                grouping.handOffCoordination(from: room, to: successorUUID)
            case let .makeStandalone(room):
                grouping.makeStandalone(room: room)
            }
        }
    }

    /// Works out which commands a move needs, given a topology. Pure, so the awkward cases
    /// - coordinators especially - are testable without touching a speaker.
    ///
    /// An empty result means the move is a no-op. Callers must check that before marking
    /// themselves busy: nothing would ever settle to clear it.
    static func commands(
        moving room: SonosRoom,
        to destination: GroupDestination,
        in groups: [SonosGroup]
    ) -> [GroupingCommand] {
        guard let current = groups.first(where: { $0.members.contains { $0.uuid == room.uuid } }) else { return [] }
        let isCoordinatorOfSharedGroup = current.id == room.uuid && !current.isStandalone
        let successor = current.members.first { $0.uuid != room.uuid }

        switch destination {
        case let .group(coordinatorUUID):
            // Can't join itself, and can't join the group it is already in.
            guard room.uuid != coordinatorUUID, current.id != coordinatorUUID else { return [] }
            guard isCoordinatorOfSharedGroup, let successor else {
                return [.join(room: room, coordinatorUUID: coordinatorUUID)]
            }
            // A coordinator sent an x-rincon: URI takes its whole group along. Hand the old
            // group to another member first so only this room travels.
            return [
                .handOffCoordination(room: room, successorUUID: successor.uuid),
                .join(room: room, coordinatorUUID: coordinatorUUID),
            ]

        case .standalone:
            guard !current.isStandalone else { return [] }
            guard isCoordinatorOfSharedGroup, let successor else {
                return [.makeStandalone(room: room)]
            }
            // BecomeCoordinatorOfStandaloneGroup does nothing to a player that already
            // coordinates its group; handing the group off is what removes it.
            return [.handOffCoordination(room: room, successorUUID: successor.uuid)]
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
