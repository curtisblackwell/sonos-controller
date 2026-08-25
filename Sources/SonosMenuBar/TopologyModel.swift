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
        // A group that has disappeared can no longer be the media key target.
        if let id = activeGroupID, !groups.contains(where: { $0.id == id }) {
            activeGroupID = nil
        }
    }

    var allRooms: [SonosRoom] { SonosTopology.allRooms(in: groups) }

    func group(containing room: SonosRoom) -> SonosGroup? {
        groups.first { $0.members.contains(room) }
    }

    // MARK: - Actions

    func move(room: SonosRoom, to destination: GroupDestination) {
        switch destination {
        case let .group(coordinatorUUID):
            guard group(containing: room)?.id != coordinatorUUID else { return }
            isBusy = true
            grouping.join(room: room, coordinatorUUID: coordinatorUUID)
        case .standalone:
            // Already the sole member of its own group - nothing to do.
            guard group(containing: room)?.isStandalone != true else { return }
            isBusy = true
            grouping.makeStandalone(room: room)
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
