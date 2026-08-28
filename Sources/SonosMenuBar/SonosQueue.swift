import Foundation
import os.log

/// What the user asked for when they picked something in a list.
enum PlayIntent: Equatable {
    /// Start this now. Never destructive: the queue the user already had survives, except when
    /// the thing picked is itself a container, which legitimately becomes the new source.
    case now
    /// Insert after the current track.
    case next
    /// Append to the end of the queue.
    case last
}

/// Which track `Seek` should jump to.
enum SeekTarget: Equatable {
    /// A position known while planning - a queue row's own place in the queue.
    case number(Int)
    /// Wherever `AddURIToQueue` just put the track. Only the service knows: `EnqueueAsNext`
    /// inserts relative to the track currently playing, and the reply reports the position it
    /// chose in `FirstTrackNumberEnqueued`. Guessing it would jump to the wrong song.
    case lastEnqueued
}

/// One AVTransport call in a play sequence. Kept as data rather than performed inline so the
/// awkward part - which calls a given item needs, and in what order - is testable without a
/// speaker, the same way `TopologyModel.commands` makes grouping testable.
enum QueueCommand: Equatable {
    case setTransportURI(uri: String, metadata: String)
    case addToQueue(uri: String, metadata: String, position: Int, asNext: Bool)
    case seekToTrack(SeekTarget)
    case play
}

/// Puts things in the queue and starts them.
///
/// Two distinctions drive everything here.
///
/// The first is *container versus track*, read from the playback URI's scheme rather than from
/// DIDL. A Sonos favorite pointing at a Spotify album is a DIDL `<item>` whose `<res>` is an
/// `x-rincon-cpcontainer:` URI - so the element name lies about how to play it, and the scheme
/// doesn't.
///
/// The second is *already in the queue versus not*. Playing a row that is in the queue is a
/// jump, and must not touch the queue's contents at all. Playing a track from anywhere else
/// inserts it after the current one and jumps to that. Neither clears anything: a queue is
/// something the user built, and no single click on a song should be able to destroy it.
enum SonosQueue {
    private static let log = Logger(subsystem: "com.curtisblackwell.sonos-controller", category: "queue")

    /// URI schemes that name something with tracks inside it. A container is played by being
    /// made the transport source outright; anything else is a single track and goes through
    /// the queue.
    private static let containerSchemes = ["x-rincon-cpcontainer:", "x-rincon-playlist:", "x-rincon-queue:", "file:"]

    static func isContainerURI(_ uri: String) -> Bool {
        containerSchemes.contains { uri.hasPrefix($0) }
    }

    /// The queue as a transport source. Playing from the queue means pointing the coordinator
    /// at its own queue first - Sonos will not switch back on its own, so a `Seek` by track
    /// number fails, and a newly added track silently never starts, whenever the current
    /// session was begun from the Sonos or Spotify app.
    static func queueURI(coordinatorUUID: String) -> String {
        "x-rincon-queue:\(coordinatorUUID)#0"
    }

    /// Works out the calls one item needs. Pure.
    ///
    /// `DesiredFirstTrackNumberEnqueued` is 1-based and 0 means append, so nothing here needs
    /// to know how long the queue is. `.next` appends with `EnqueueAsNext` and lets the service
    /// place it: it knows where the current track is, and we would only be guessing.
    static func commands(
        for item: MediaItem,
        intent: PlayIntent,
        coordinatorUUID: String
    ) -> [QueueCommand] {
        guard let uri = item.playURI else { return [] }
        let metadata = item.playMetadata ?? ""

        if isContainerURI(uri) {
            switch intent {
            case .now:
                // A container replaces the source outright, which is what picking an album or
                // a playlist means. No queue manipulation: the container *becomes* the queue.
                return [.setTransportURI(uri: uri, metadata: metadata), .play]
            case .next, .last:
                // AddURIToQueue accepts a container URI and flattens it into the queue, which
                // is how "add this album to the end" works without enumerating its tracks -
                // which, for a music service container, we are not able to do.
                return [.addToQueue(uri: uri, metadata: metadata, position: 0, asNext: intent == .next)]
            }
        }

        switch intent {
        case .now:
            let activate = QueueCommand.setTransportURI(uri: queueURI(coordinatorUUID: coordinatorUUID), metadata: "")
            // Already in the queue: this is a jump. Adding it again would duplicate the row,
            // and clearing to make it track 1 would throw away everything else the user queued.
            if let position = item.queuePosition {
                return [activate, .seekToTrack(.number(position)), .play]
            }
            // From somewhere else: insert after the current track and jump to it, so the rest
            // of the queue is still there afterwards.
            return [
                .addToQueue(uri: uri, metadata: metadata, position: 0, asNext: true),
                activate,
                .seekToTrack(.lastEnqueued),
                .play,
            ]
        case .next, .last:
            return [.addToQueue(uri: uri, metadata: metadata, position: 0, asNext: intent == .next)]
        }
    }

    // MARK: - Sending

    /// Runs a command sequence in order against the group's coordinator.
    ///
    /// Serialized, and for the same reason grouping commands are: each call changes the state
    /// the next one assumes. `Play` before `AddURIToQueue` has landed starts the wrong track,
    /// and a `Seek` by track number before the coordinator is pointed at its queue fails
    /// outright. Completion runs on the main thread.
    static func perform(
        _ commands: [QueueCommand],
        coordinatorIP: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        perform(commands, coordinatorIP: coordinatorIP, enqueuedTrackNumber: nil, completion: completion)
    }

    private static func perform(
        _ commands: [QueueCommand],
        coordinatorIP: String,
        enqueuedTrackNumber: Int?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let command = commands.first else {
            DispatchQueue.main.async { completion(.success(())) }
            return
        }
        let remaining = Array(commands.dropFirst())

        guard let action = action(for: command, enqueuedTrackNumber: enqueuedTrackNumber) else {
            // Only reachable for a jump whose target the add never reported. The track is in
            // the queue either way, so carrying on and letting Play start it beats aborting.
            log.error("Skipping a queue jump with no known track number")
            perform(remaining, coordinatorIP: coordinatorIP, enqueuedTrackNumber: enqueuedTrackNumber, completion: completion)
            return
        }

        SonosControl.send(action: action, to: coordinatorIP) { result in
            switch result {
            case let .failure(error):
                log.error("Queue command \(action.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async { completion(.failure(error)) }
            case let .success(data):
                var enqueued = enqueuedTrackNumber
                if case .addToQueue = command {
                    enqueued = SonosSOAP.intValue(named: "FirstTrackNumberEnqueued", in: data) ?? enqueued
                }
                perform(remaining, coordinatorIP: coordinatorIP, enqueuedTrackNumber: enqueued, completion: completion)
            }
        }
    }

    private static func action(for command: QueueCommand, enqueuedTrackNumber: Int?) -> SonosAction? {
        switch command {
        case let .setTransportURI(uri, metadata):
            return .setAVTransportURI(uri: uri, metadata: metadata)
        case let .addToQueue(uri, metadata, position, asNext):
            return .addURIToQueue(uri: uri, metadata: metadata, desiredFirstTrackNumber: position, enqueueAsNext: asNext)
        case let .seekToTrack(target):
            switch target {
            case let .number(number):
                return .seekTrack(number: number)
            case .lastEnqueued:
                return enqueuedTrackNumber.map { .seekTrack(number: $0) }
            }
        case .play:
            return .play
        }
    }
}
