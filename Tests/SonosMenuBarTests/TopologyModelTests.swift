import Testing
import Foundation
@testable import SonosMenuBar

/// These all exercise paths that return before any command is enqueued, so nothing here
/// touches the network. The point is the guard placement: an early return that happens
/// *after* `isBusy` is set would latch the spinner forever, because nothing would ever
/// settle to clear it.
struct TopologyModelTests {
    private func room(_ uuid: String, _ name: String, _ ip: String = "192.168.1.50") -> SonosRoom {
        SonosRoom(uuid: uuid, name: name, ipAddress: ip)
    }

    private func model(with groups: [SonosGroup]) -> TopologyModel {
        let model = TopologyModel()
        model.update(groups: groups)
        return model
    }

    @Test func movingARoomTheTopologyDoesNotKnowAboutIsANoOp() {
        let model = model(with: [])
        model.move(room: room("RINCON_GHOST", "Ghost"), to: .standalone)
        #expect(!model.isBusy)
    }

    @Test func joiningTheGroupItIsAlreadyInIsANoOp() {
        let living = room("RINCON_LIVING", "Living Room")
        let kitchen = room("RINCON_KITCHEN", "Kitchen", "192.168.1.51")
        let group = SonosGroup(id: living.uuid, coordinatorIP: living.ipAddress, members: [living, kitchen])
        let model = model(with: [group])

        model.move(room: kitchen, to: .group(coordinatorUUID: living.uuid))
        #expect(!model.isBusy)
    }

    @Test func aRoomCannotJoinItself() {
        let office = room("RINCON_OFFICE", "Office")
        let model = model(with: [SonosGroup(id: office.uuid, coordinatorIP: office.ipAddress, members: [office])])

        model.move(room: office, to: .group(coordinatorUUID: office.uuid))
        #expect(!model.isBusy)
    }

    @Test func ungroupingARoomThatIsAlreadyAloneIsANoOp() {
        let office = room("RINCON_OFFICE", "Office")
        let model = model(with: [SonosGroup(id: office.uuid, coordinatorIP: office.ipAddress, members: [office])])

        model.move(room: office, to: .standalone)
        #expect(!model.isBusy)
    }

    // MARK: - Command planning

    private var living: SonosRoom { room("RINCON_LIVING", "Living Room", "192.168.1.50") }
    private var kitchen: SonosRoom { room("RINCON_KITCHEN", "Kitchen", "192.168.1.51") }
    private var office: SonosRoom { room("RINCON_OFFICE", "Office", "192.168.1.52") }
    private var patio: SonosRoom { room("RINCON_PATIO", "Patio", "192.168.1.53") }

    /// [Living(coord), Kitchen, Office] plus Patio on its own.
    private var household: [SonosGroup] {
        [
            SonosGroup(id: living.uuid, coordinatorIP: living.ipAddress, members: [living, kitchen, office]),
            SonosGroup(id: patio.uuid, coordinatorIP: patio.ipAddress, members: [patio]),
        ]
    }

    @Test func ungroupingAPlainMemberJustLeaves() {
        let commands = TopologyModel.commands(moving: kitchen, to: .standalone, in: household)
        #expect(commands == [.makeStandalone(room: kitchen)])
    }

    @Test func ungroupingACoordinatorHandsTheGroupOffInstead() {
        // BecomeCoordinatorOfStandaloneGroup does nothing to a player that already
        // coordinates its group, so the only way out is to delegate the group away.
        let commands = TopologyModel.commands(moving: living, to: .standalone, in: household)
        #expect(commands == [.handOffCoordination(room: living, successorUUID: kitchen.uuid)])
    }

    @Test func movingACoordinatorIntoAnotherGroupHandsOffFirst() {
        // Sending x-rincon: straight to a coordinator drags its whole group along; the
        // handoff is what lets it travel alone.
        let commands = TopologyModel.commands(moving: living, to: .group(coordinatorUUID: patio.uuid), in: household)
        #expect(commands == [
            .handOffCoordination(room: living, successorUUID: kitchen.uuid),
            .join(room: living, coordinatorUUID: patio.uuid),
        ])
    }

    @Test func movingAPlainMemberIntoAnotherGroupIsASingleJoin() {
        let commands = TopologyModel.commands(moving: office, to: .group(coordinatorUUID: patio.uuid), in: household)
        #expect(commands == [.join(room: office, coordinatorUUID: patio.uuid)])
    }

    @Test func aStandaloneRoomJoiningAGroupNeedsNoHandoff() {
        // It coordinates its own group of one, but there is no group left behind to hand on.
        let commands = TopologyModel.commands(moving: patio, to: .group(coordinatorUUID: living.uuid), in: household)
        #expect(commands == [.join(room: patio, coordinatorUUID: living.uuid)])
    }

    @Test func noOpMovesPlanNothing() {
        #expect(TopologyModel.commands(moving: patio, to: .standalone, in: household).isEmpty)
        #expect(TopologyModel.commands(moving: kitchen, to: .group(coordinatorUUID: living.uuid), in: household).isEmpty)
        #expect(TopologyModel.commands(moving: living, to: .group(coordinatorUUID: living.uuid), in: household).isEmpty)
        #expect(TopologyModel.commands(moving: room("RINCON_GHOST", "Ghost"), to: .standalone, in: household).isEmpty)
    }

    @Test func groupLookupMatchesOnUUIDNotWholeRoom() {
        let living = room("RINCON_LIVING", "Living Room")
        let group = SonosGroup(id: living.uuid, coordinatorIP: living.ipAddress, members: [living])
        let model = model(with: [group])

        // What a drag payload looks like after the room was renamed or picked up a new
        // DHCP lease mid-session; full-value equality would miss it.
        let stale = room("RINCON_LIVING", "Lounge", "192.168.1.99")
        #expect(model.group(containing: stale)?.id == living.uuid)
    }
}
