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
