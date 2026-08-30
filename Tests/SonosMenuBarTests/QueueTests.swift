import Testing
import Foundation
@testable import SonosMenuBar

private let coordinatorUUID = "RINCON_5CAAFDF7D15C01400"
private let queueSource = "x-rincon-queue:RINCON_5CAAFDF7D15C01400#0"
private let trackURI = "x-sonos-spotify:spotify%3atrack%3aABC?sid=12&flags=8232&sn=13"
private let containerURI = "x-rincon-cpcontainer:00040000spotify%3aalbum%3aXYZ?sid=12&flags=4&sn=13"

/// A track that is not in the queue - a favorite, or a search result.
private func looseTrack() -> MediaItem {
    MediaItem(id: "FV:2/7", title: "Feel It All Around", playURI: trackURI, playMetadata: "<DIDL-Lite/>")
}

/// A row of the queue itself.
private func queueRow(_ position: Int) -> MediaItem {
    MediaItem(id: "Q:0/\(position)", title: "Cherry", playURI: trackURI)
}

private func container() -> MediaItem {
    MediaItem(id: "FV:2/30", title: "Classics", playURI: containerURI, playMetadata: "<DIDL-Lite/>", isContainer: true)
}

struct QueuePositionTests {
    @Test func queueRowsKnowTheirTrackNumber() {
        #expect(queueRow(1).queuePosition == 1)
        #expect(queueRow(47).queuePosition == 47)
    }

    @Test func nonQueueItemsHaveNoPosition() {
        #expect(looseTrack().queuePosition == nil)
        #expect(container().queuePosition == nil)
        #expect(MediaItem(id: "SQ:2", title: "A playlist").queuePosition == nil)
        // A saved-queue row is not a live-queue row, and must not be mistaken for one.
        #expect(MediaItem(id: "SQ:2/3", title: "Track in a saved queue").queuePosition == nil)
    }

    @Test func aMalformedQueueIDHasNoPosition() {
        #expect(MediaItem(id: "Q:0/", title: "x").queuePosition == nil)
        #expect(MediaItem(id: "Q:0/abc", title: "x").queuePosition == nil)
    }
}

struct ContainerDetectionTests {
    /// The scheme is the signal, not the DIDL element: a favorite pointing at a Spotify album
    /// arrives as an `<item>` whose `<res>` is a container URI, so believing the element name
    /// would try to play an album as if it were a song.
    @Test func containerSchemesAreRecognised() {
        #expect(SonosQueue.isContainerURI(containerURI))
        #expect(SonosQueue.isContainerURI("file:///jffs/settings/savedqueues.rsq#2"))
        #expect(SonosQueue.isContainerURI("x-rincon-queue:RINCON_ABC#0"))
    }

    @Test func trackSchemesAreNotContainers() {
        #expect(!SonosQueue.isContainerURI(trackURI))
        #expect(!SonosQueue.isContainerURI("x-file-cifs://nas/music/a.flac"))
        #expect(!SonosQueue.isContainerURI("x-sonosapi-stream:s12345?sid=254"))
    }

    @Test func queueURIUsesTheCoordinator() {
        #expect(SonosQueue.queueURI(coordinatorUUID: coordinatorUUID) == queueSource)
    }
}

/// The rule these all exist to hold: nothing reachable from clicking a song may empty the
/// queue. A queue is something the user built by hand, and losing it is not undoable.
struct QueueIsNeverDestroyedTests {
    @Test func noIntentOnAnyItemEverClearsTheQueue() {
        for item in [looseTrack(), queueRow(3), container()] {
            for intent in [PlayIntent.now, .next, .last] {
                let commands = SonosQueue.commands(for: item, intent: intent, coordinatorUUID: coordinatorUUID)
                #expect(!commands.contains { command in
                    if case .addToQueue = command { return false }
                    if case .setTransportURI = command { return false }
                    if case .seekToTrack = command { return false }
                    if case .play = command { return false }
                    return true
                })
            }
        }
    }

    /// Playing a row that is already in the queue must not add to it either - that would
    /// duplicate the track every time the user double-clicked it.
    @Test func playingAQueueRowDoesNotAddAnything() {
        let commands = SonosQueue.commands(for: queueRow(4), intent: .now, coordinatorUUID: coordinatorUUID)
        #expect(!commands.contains { if case .addToQueue = $0 { return true } else { return false } })
    }
}

struct PlayNowPlanningTests {
    /// Double-clicking a queue row is a jump: point at the queue, seek to that track number,
    /// play. The queue's contents are untouched.
    @Test func playingAQueueRowJumpsToItsTrackNumber() {
        let commands = SonosQueue.commands(for: queueRow(12), intent: .now, coordinatorUUID: coordinatorUUID)
        #expect(commands == [
            .setTransportURI(uri: queueSource, metadata: ""),
            .seekToTrack(.number(12)),
            .play,
        ])
    }

    /// A track from anywhere else is inserted after the current one and jumped to, so whatever
    /// was queued still plays afterwards.
    @Test func playingALooseTrackInsertsItAsNextAndJumpsToIt() {
        let commands = SonosQueue.commands(for: looseTrack(), intent: .now, coordinatorUUID: coordinatorUUID)
        #expect(commands == [
            .addToQueue(uri: trackURI, metadata: "<DIDL-Lite/>", position: 0, asNext: true),
            .setTransportURI(uri: queueSource, metadata: ""),
            .seekToTrack(.lastEnqueued),
            .play,
        ])
    }

    /// The position comes from the service's own reply rather than from planning, because
    /// `EnqueueAsNext` places the track relative to whatever is playing right now.
    @Test func aLooseTrackSeeksToWhereTheServiceSaidItLanded() {
        let commands = SonosQueue.commands(for: looseTrack(), intent: .now, coordinatorUUID: coordinatorUUID)
        #expect(commands.contains(.seekToTrack(.lastEnqueued)))
        #expect(!commands.contains(.seekToTrack(.number(1))))
    }

    @Test func playingAContainerReplacesTheSourceOutright() {
        let commands = SonosQueue.commands(for: container(), intent: .now, coordinatorUUID: coordinatorUUID)
        #expect(commands == [
            .setTransportURI(uri: containerURI, metadata: "<DIDL-Lite/>"),
            .play,
        ])
    }

    /// Ordering is the whole point of planning these rather than firing them. A `Seek` by track
    /// number before the coordinator is pointed at its own queue fails outright - which is the
    /// case that breaks when a session was started from the Sonos or Spotify app.
    @Test func theCoordinatorIsPointedAtTheQueueBeforeSeekingAndPlaying() {
        for item in [queueRow(5), looseTrack()] {
            let commands = SonosQueue.commands(for: item, intent: .now, coordinatorUUID: coordinatorUUID)
            let activate = commands.firstIndex(of: .setTransportURI(uri: queueSource, metadata: ""))
            let seek = commands.firstIndex { if case .seekToTrack = $0 { return true } else { return false } }
            let play = commands.firstIndex(of: .play)
            #expect(activate != nil && seek != nil && play != nil)
            #expect(activate! < seek!)
            #expect(seek! < play!)
        }
    }

    /// The add has to happen before the queue is activated and seeked into, or there is
    /// nothing at the position we jump to.
    @Test func aLooseTrackIsAddedBeforeTheQueueIsActivated() {
        let commands = SonosQueue.commands(for: looseTrack(), intent: .now, coordinatorUUID: coordinatorUUID)
        let add = commands.firstIndex { if case .addToQueue = $0 { return true } else { return false } }
        let activate = commands.firstIndex(of: .setTransportURI(uri: queueSource, metadata: ""))
        #expect(add! < activate!)
    }
}

struct QueueingPlanningTests {
    /// `DesiredFirstTrackNumberEnqueued` 0 means append, so neither of these needs to know how
    /// long the queue is - and `EnqueueAsNext` is what distinguishes them.
    @Test func playNextAndAddToQueueBothAppendAndDifferOnlyInEnqueueAsNext() {
        let next = SonosQueue.commands(for: looseTrack(), intent: .next, coordinatorUUID: coordinatorUUID)
        let last = SonosQueue.commands(for: looseTrack(), intent: .last, coordinatorUUID: coordinatorUUID)
        #expect(next == [.addToQueue(uri: trackURI, metadata: "<DIDL-Lite/>", position: 0, asNext: true)])
        #expect(last == [.addToQueue(uri: trackURI, metadata: "<DIDL-Lite/>", position: 0, asNext: false)])
    }

    /// Neither should disturb what is currently playing.
    @Test func queueingDoesNotPlay() {
        for intent in [PlayIntent.next, .last] {
            for item in [looseTrack(), container()] {
                let commands = SonosQueue.commands(for: item, intent: intent, coordinatorUUID: coordinatorUUID)
                #expect(!commands.contains(.play))
                #expect(!commands.contains { if case .seekToTrack = $0 { return true } else { return false } })
            }
        }
    }

    @Test func aContainerCanBeAppendedWithoutBeingExpanded() {
        let commands = SonosQueue.commands(for: container(), intent: .last, coordinatorUUID: coordinatorUUID)
        #expect(commands == [.addToQueue(uri: containerURI, metadata: "<DIDL-Lite/>", position: 0, asNext: false)])
    }
}

struct QueueMetadataTests {
    @Test func anItemWithNothingToPlayPlansNothing() {
        let unplayable = MediaItem(id: "A:ARTIST", title: "Artists", isContainer: true, canExpand: true)
        for intent in [PlayIntent.now, .next, .last] {
            #expect(SonosQueue.commands(for: unplayable, intent: intent, coordinatorUUID: coordinatorUUID).isEmpty)
        }
    }

    /// Favorites carry their own metadata and it must be passed through untouched - it holds
    /// the credential token, and a favorite played without it fails.
    @Test func metadataIsCarriedThroughRatherThanRebuilt() {
        let favorite = MediaItem(
            id: "FV:2/18",
            title: "Ambient Focus",
            playURI: "x-rincon-cpcontainer:1006004cX?sid=284&flags=76&sn=3",
            playMetadata: "<DIDL-Lite><desc id=\"cdudn\">SA_RINCON72711_X_#Svc72711-0-Token</desc></DIDL-Lite>"
        )
        let commands = SonosQueue.commands(for: favorite, intent: .now, coordinatorUUID: coordinatorUUID)
        guard case let .setTransportURI(_, metadata) = commands.first else {
            Issue.record("expected the container to be set as the transport source")
            return
        }
        #expect(metadata.contains("SA_RINCON72711_X_#Svc72711-0-Token"))
    }

    /// An item with no stored metadata sends an empty string rather than the word "nil".
    @Test func missingMetadataBecomesAnEmptyArgument() {
        let bare = MediaItem(id: "FV:2/9", title: "Track", playURI: "x-sonos-spotify:t?sid=12&sn=13")
        let commands = SonosQueue.commands(for: bare, intent: .last, coordinatorUUID: coordinatorUUID)
        #expect(commands == [.addToQueue(uri: "x-sonos-spotify:t?sid=12&sn=13", metadata: "", position: 0, asNext: false)])
    }
}

/// Unlike every other builder in this file, playing a whole album is allowed to clear the queue
/// - it is only reachable from an explicit "Play Album" button, never from clicking a track.
struct AlbumPlaybackPlanningTests {
    private func albumTrack(_ id: String) -> MediaItem {
        MediaItem(id: id, title: "Track \(id)", playURI: "x-sonos-spotify:spotify%3atrack%3a\(id)?sid=12&flags=8232&sn=13")
    }

    @Test func playingAnAlbumClearsTheQueueThenAddsEveryTrackInOrder() {
        let tracks = [albumTrack("A"), albumTrack("B"), albumTrack("C")]
        let commands = SonosQueue.commands(forAlbumTracks: tracks, coordinatorUUID: coordinatorUUID)
        #expect(commands == [
            .clearQueue,
            .addToQueue(uri: tracks[0].playURI!, metadata: "", position: 0, asNext: false),
            .addToQueue(uri: tracks[1].playURI!, metadata: "", position: 0, asNext: false),
            .addToQueue(uri: tracks[2].playURI!, metadata: "", position: 0, asNext: false),
            .setTransportURI(uri: queueSource, metadata: ""),
            .seekToTrack(.number(1)),
            .play,
        ])
    }

    /// A track with no `playURI` yet (credentials not discovered) is skipped rather than
    /// failing the whole album - the rest can still play.
    @Test func tracksWithNothingToPlayAreSkipped() {
        let unplayable = MediaItem(id: "X", title: "No URI")
        let commands = SonosQueue.commands(forAlbumTracks: [unplayable, albumTrack("A")], coordinatorUUID: coordinatorUUID)
        #expect(commands.filter { if case .addToQueue = $0 { return true } else { return false } }.count == 1)
    }

    @Test func anAlbumWithNothingPlayablePlansNothing() {
        let commands = SonosQueue.commands(forAlbumTracks: [MediaItem(id: "X", title: "No URI")], coordinatorUUID: coordinatorUUID)
        #expect(commands.isEmpty)
    }
}

struct SeekEnvelopeTests {
    @Test func seekingToATrackUsesTrackNumberUnit() {
        let envelope = SonosControl.soapEnvelope(action: .seekTrack(number: 12))
        #expect(envelope.contains("<u:Seek"))
        #expect(envelope.contains("<Unit>TRACK_NR</Unit>"))
        #expect(envelope.contains("<Target>12</Target>"))
    }

    /// The time-based seek the progress slider uses is unchanged.
    @Test func seekingToATimeStillUsesRelativeTime() {
        let envelope = SonosControl.soapEnvelope(action: .seek(target: "0:01:30"))
        #expect(envelope.contains("<Unit>REL_TIME</Unit>"))
        #expect(envelope.contains("<Target>0:01:30</Target>"))
    }
}
