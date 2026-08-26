import Foundation
import os.log

/// Play/pause state for the active group. AVTransport has no household-wide GENA endpoint
/// the way ZoneGroupTopology does, so - like `VolumeModel` - this polls, and only while the
/// window showing it is on screen.
///
/// Main thread only. `SonosControl`'s completions land on a URLSession queue, so `refresh`
/// hops back before touching `isPlaying`.
final class PlaybackModel: ObservableObject {
    private static let log = Logger(subsystem: "com.curtisblackwell.sonos-controller", category: "playback-model")
    private static let pollInterval: TimeInterval = 2.5

    /// nil until a reading has landed for the current coordinator, or when there is no
    /// active group to read - both cases the button shows as unknown rather than guessing.
    @Published private(set) var isPlaying: Bool?

    private var coordinatorIP: String?
    private var pollTimer: Timer?
    /// Bumped by every command and every coordinator change, so a poll already in flight
    /// can't land after and stomp a fresher optimistic flip or a switch to another group.
    private var generation = 0

    var isWatching: Bool { pollTimer != nil }

    // MARK: - Topology

    /// Called with the active group's coordinator IP whenever it might have changed - a new
    /// selection, a regroup, the household resolving after launch.
    func update(coordinatorIP: String?) {
        guard coordinatorIP != self.coordinatorIP else { return }
        self.coordinatorIP = coordinatorIP
        generation += 1
        isPlaying = nil
        if isWatching { refresh() }
    }

    // MARK: - Polling

    func startPolling() {
        guard pollTimer == nil else { return }
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refresh() {
        guard let ip = coordinatorIP else { return }
        let requestGeneration = generation
        SonosControl.send(action: .getTransportInfo, to: ip) { [weak self] data in
            DispatchQueue.main.async {
                guard let self, requestGeneration == self.generation, ip == self.coordinatorIP else { return }
                guard let data, let state = SonosControl.currentTransportState(from: data) else { return }
                self.isPlaying = state == "PLAYING" || state == "TRANSITIONING"
            }
        }
    }

    // MARK: - Actions

    func togglePlayPause() {
        guard let ip = coordinatorIP else { return }
        // Flip optimistically - otherwise the button sits unchanged for up to pollInterval
        // after every press, which reads as the press having been ignored.
        if let isPlaying { self.isPlaying = !isPlaying }
        generation += 1
        SonosControl.togglePlayPause(ip: ip)
    }

    func next() {
        guard let ip = coordinatorIP else { return }
        generation += 1
        SonosControl.send(action: .next, to: ip)
    }

    func previous() {
        guard let ip = coordinatorIP else { return }
        generation += 1
        SonosControl.send(action: .previous, to: ip)
    }
}
