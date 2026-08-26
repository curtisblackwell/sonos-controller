import Foundation
import os.log

/// Applies grouping changes to the household.
///
/// Both operations are AVTransport calls addressed to the room *being moved*, not to the
/// group it is joining or leaving - the same endpoint `SonosControl` already talks to.
///
/// Commands are serialized. Each one changes the topology that the next one's UI state was
/// derived from, so firing several concurrently (easy to do by dragging quickly) produces
/// interleaved results that don't match what the user asked for. The queue also gives us a
/// single point to refresh from once everything has settled.
final class SonosGrouping {
    private static let log = Logger(subsystem: "com.curtisblackwell.sonos-controller", category: "grouping")

    /// Sonos needs a moment after a grouping command before GetZoneGroupState reflects it.
    /// Refreshing immediately reliably returns the *old* topology and the UI snaps back.
    private static let settleDelay: TimeInterval = 0.6

    private let queue = DispatchQueue(label: "com.curtisblackwell.sonos-controller.grouping")
    private let semaphore = DispatchSemaphore(value: 0)

    /// Called on the main thread once the queue has drained, so the caller can refetch.
    var onDidSettle: (() -> Void)?
    /// Called on the main thread with a user-presentable message when a command fails.
    var onError: ((String) -> Void)?

    /// Main thread only - incremented by the enqueueing UI, decremented on the main queue.
    private var pendingCount = 0

    var isBusy: Bool { pendingCount > 0 }

    /// Puts `room` into the group coordinated by `coordinatorUUID`.
    ///
    /// Preconditions are the caller's job - `TopologyModel.move` is the single place that
    /// decides whether a move is a no-op. A second guard here would silently skip the
    /// enqueue and strand the caller's in-progress state, since nothing would ever settle.
    func join(room: SonosRoom, coordinatorUUID: String) {
        Self.log.notice("Joining \(room.name, privacy: .public) to \(coordinatorUUID, privacy: .public)")
        enqueue(
            action: .setAVTransportURI(uri: "x-rincon:\(coordinatorUUID)", metadata: ""),
            on: room,
            describedAs: "add \(room.name) to the group"
        )
    }

    /// Hands coordination of `room`'s group to `successorUUID` and drops `room` out of it.
    /// The only way to remove a coordinator: `BecomeCoordinatorOfStandaloneGroup` sent to a
    /// player that already coordinates its group returns 200 and changes nothing.
    func handOffCoordination(from room: SonosRoom, to successorUUID: String) {
        Self.log.notice("Handing \(room.name, privacy: .public) group to \(successorUUID, privacy: .public)")
        enqueue(
            action: .delegateGroupCoordinationTo(newCoordinator: successorUUID, rejoinGroup: false),
            on: room,
            describedAs: "remove \(room.name) from its group"
        )
    }

    /// Pulls a non-coordinating `room` out of whatever group it is currently in.
    func makeStandalone(room: SonosRoom) {
        Self.log.notice("Ungrouping \(room.name, privacy: .public)")
        enqueue(
            action: .becomeCoordinatorOfStandaloneGroup,
            on: room,
            describedAs: "remove \(room.name) from its group"
        )
    }

    private func enqueue(action: SonosAction, on room: SonosRoom, describedAs description: String) {
        pendingCount += 1
        queue.async { [weak self] in
            guard let self else { return }
            SonosControl.send(action: action, to: room.ipAddress) { result in
                if case let .failure(error) = result {
                    let message = "Couldn't \(description): \(error.localizedDescription)"
                    DispatchQueue.main.async { self.onError?(message) }
                }
                self.semaphore.signal()
            }
            self.semaphore.wait()

            // Let the household converge before anyone asks it what the topology is.
            Thread.sleep(forTimeInterval: Self.settleDelay)

            DispatchQueue.main.async {
                self.pendingCount -= 1
                if self.pendingCount == 0 { self.onDidSettle?() }
            }
        }
    }
}
