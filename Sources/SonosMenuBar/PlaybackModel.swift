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
    @Published private(set) var track: TrackMetadata?
    @Published private(set) var durationSeconds: Int?
    /// The value the poll last read. `elapsedSeconds` is what the view actually binds to -
    /// it prefers a live seek drag over this the same way `VolumeModel.volume(forGroup:)`
    /// prefers a live volume drag over its last poll reading.
    @Published private var polledElapsedSeconds: Int?
    private var seekOverride: Int?

    var elapsedSeconds: Int? { seekOverride ?? polledElapsedSeconds }

    private var coordinatorIP: String?
    private var pollTimer: Timer?
    private var tickTimer: Timer?
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
        track = nil
        durationSeconds = nil
        polledElapsedSeconds = nil
        seekOverride = nil
        if isWatching { refresh() }
    }

    // MARK: - Polling

    func startPolling() {
        guard pollTimer == nil else { return }
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        tickTimer?.invalidate()
        tickTimer = nil
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
        SonosControl.send(action: .getPositionInfo, to: ip) { [weak self] data in
            DispatchQueue.main.async {
                guard let self, requestGeneration == self.generation, ip == self.coordinatorIP else { return }
                guard let data else { return }
                self.track = SonosControl.trackMetadata(from: data, coordinatorIP: ip)
                self.durationSeconds = SonosControl.trackDurationSeconds(from: data)
                // A seek already in flight owns the elapsed time until it lands - a poll that
                // started before the drag ended would otherwise snap the slider back.
                guard self.seekOverride == nil else { return }
                self.polledElapsedSeconds = SonosControl.relTimeSeconds(from: data)
            }
        }
    }

    /// Advances the slider between polls, so a progress bar that only moved once every 2.5s
    /// didn't read as broken. Only ticks what the poll itself would eventually confirm.
    private func tick() {
        guard isPlaying == true, seekOverride == nil,
              let elapsed = polledElapsedSeconds
        else { return }
        let next = elapsed + 1
        polledElapsedSeconds = durationSeconds.map { min(next, $0) } ?? next
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

    /// Restarts the current track once playback is more than a few seconds in, matching how
    /// a physical "previous" button behaves; only jumps to the prior track when still near
    /// the start.
    func previous() {
        guard let ip = coordinatorIP else { return }
        SonosControl.send(action: .getPositionInfo, to: ip) { data in
            guard let data, let seconds = SonosControl.relTimeSeconds(from: data), seconds > 3 else {
                SonosControl.send(action: .previous, to: ip)
                return
            }
            SonosControl.send(action: .seek(target: "0:00:00"), to: ip)
        }
        generation += 1
    }

    // MARK: - Seeking

    /// Takes hold of the progress slider, the same reason `VolumeModel.beginGroupDrag` exists:
    /// while the user is dragging, the poll's own answer is stale by definition.
    func beginSeekDrag() {
        seekOverride = elapsedSeconds
    }

    func updateSeekDrag(to seconds: Int) {
        seekOverride = seconds
    }

    func endSeekDrag(to seconds: Int) {
        guard let ip = coordinatorIP else {
            seekOverride = nil
            return
        }
        // Flip optimistically, same as `togglePlayPause` - otherwise the slider sits at the
        // drop point for up to a poll interval before the seek is reflected.
        polledElapsedSeconds = seconds
        seekOverride = nil
        generation += 1
        SonosControl.send(action: .seek(target: SonosSOAP.formatTime(seconds: seconds)), to: ip)
    }
}
