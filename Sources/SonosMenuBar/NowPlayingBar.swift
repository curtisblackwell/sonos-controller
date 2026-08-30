import SwiftUI

/// The persistent bar along the bottom of the window: what's playing, the transport, the
/// seek slider, the household volume, and whether we're still hearing from the household.
///
/// It sits below the whole split view rather than inside the detail column, because none of
/// it is about the page you happen to be looking at - the active group and its playback are
/// the same wherever you are.
struct NowPlayingBar: View {
    @ObservedObject var model: TopologyModel
    @ObservedObject var volume: VolumeModel
    @ObservedObject var playback: PlaybackModel

    /// Tracks the bar's own width so the seek slider can scale with the window. Starts at the
    /// window minimum so the very first layout pass - before GeometryReader reports a real
    /// size - already sizes the slider correctly instead of snapping once it does.
    @State private var barWidth: CGFloat = MainWindowView.minWindowWidth

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            nowPlaying
            Spacer(minLength: 12)
            VStack(spacing: 6) {
                transportControls
                progressRow
                householdVolumeRow
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                Spacer()
                if model.isBusy {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Updating…").foregroundStyle(.secondary).font(.callout)
                    }
                }
                liveIndicator
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Fixed rather than left to size to content, so the bar doesn't grow or shrink
        // as playback state comes and goes - the transport row disappears entirely
        // with no active group, and the row heights alone wouldn't hold the gap open.
        .frame(height: 84)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { barWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, newWidth in
                        barWidth = newWidth
                    }
            }
        }
    }

    /// Album art and title/artist/album for whatever `playback` is currently reading. Reads
    /// as "Nothing Playing" rather than disappearing when there's no active group or no
    /// track - `PlaybackModel` already reports that as `track == nil`.
    private var nowPlaying: some View {
        HStack(spacing: 8) {
            albumArt
            VStack(alignment: .leading, spacing: 2) {
                Text(playback.track?.title ?? "Nothing Playing")
                    .font(.callout.bold())
                    .lineLimit(1)
                Text(playback.track?.artist ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(playback.track?.album ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var albumArt: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(.quaternary)
            .frame(width: 54, height: 54)
            .overlay {
                if let url = playback.track?.albumArtURL {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Image(systemName: "music.note").foregroundStyle(.secondary)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            }
    }

    /// Elapsed time, a seek slider, and time remaining. Degrades on its own when nothing is
    /// playing - `durationSeconds` stays nil, which disables the slider - so this needs no
    /// gate of its own.
    private var progressRow: some View {
        HStack(spacing: 6) {
            Text(Self.formatPlaybackTime(playback.elapsedSeconds ?? 0))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { Double(playback.elapsedSeconds ?? 0) },
                    set: { playback.updateSeekDrag(to: Int($0.rounded())) }
                ),
                in: 0...Double(max(playback.durationSeconds ?? 0, 1)),
                onEditingChanged: { editing in
                    if editing {
                        playback.beginSeekDrag()
                    } else {
                        playback.endSeekDrag(to: playback.elapsedSeconds ?? 0)
                    }
                }
            )
            .frame(width: max(400, barWidth * 2 / 3))
            .disabled(playback.durationSeconds == nil)
            .accessibilityLabel("Playback position")
            .accessibilityValue(playback.elapsedSeconds.map { "\(Self.formatPlaybackTime($0)) elapsed" } ?? "Not known yet")

            Text(remainingLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
        }
    }

    private var remainingLabel: String {
        guard let duration = playback.durationSeconds else { return "-:--" }
        return "-" + Self.formatPlaybackTime(max(duration - (playback.elapsedSeconds ?? 0), 0))
    }

    static func formatPlaybackTime(_ seconds: Int) -> String {
        let seconds = max(seconds, 0)
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// The household's own volume row, one rung up from the group sliders on the Speakers
    /// page: every room in every group, moved in the same proportion. Paired with the same
    /// "match to quietest" action a group row offers, just aimed at the whole household.
    @ViewBuilder
    private var householdVolumeRow: some View {
        if !model.groups.isEmpty {
            HStack(spacing: 8) {
                VolumeSlider(
                    value: volume.volumeForHousehold(),
                    isMuted: volume.isHouseholdMuted(),
                    label: "the whole house",
                    setVolume: { volume.setHouseholdVolume($0) },
                    toggleMute: { volume.toggleHouseholdMute() },
                    onEditingChanged: { editing in
                        if editing {
                            volume.beginHouseholdDrag()
                        } else {
                            volume.endHouseholdDrag()
                        }
                    }
                )

                Button("Match Quietest") {
                    volume.syncEverythingToQuietest()
                }
                .controlSize(.small)
                .disabled(volume.isSyncing)
                .help("Set every speaker in the house to the volume of the quietest one.")
            }
        }
    }

    /// Only shown once there's an active group to target - matches the star toggle that
    /// picks one, and the media keys these buttons mirror.
    @ViewBuilder
    private var transportControls: some View {
        if model.activeGroupID != nil {
            HStack(spacing: 4) {
                transportButton(systemImage: "backward.end.fill", help: "Previous Track") {
                    playback.previous()
                }
                transportButton(
                    systemImage: playback.isPlaying == true ? "pause.fill" : "play.fill",
                    help: playback.isPlaying == true ? "Pause" : "Play"
                ) {
                    playback.togglePlayPause()
                }
                .disabled(playback.isPlaying == nil)
                transportButton(systemImage: "forward.end.fill", help: "Next Track") {
                    playback.next()
                }
            }
        }
    }

    private func transportButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    /// Replaces what used to be a Refresh button. The household pushes its changes now, and
    /// the subscription repairs itself, so there is nothing left for the user to trigger -
    /// what they actually need to know is whether what they're looking at is current.
    @ViewBuilder
    private var liveIndicator: some View {
        if model.isReceivingLiveUpdates {
            Label {
                Text("Connected to Sonos")
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.green)
            }
            .font(.callout)
            .help("Changes made in the Sonos app show up here automatically.")
        } else {
            Label("Reconnecting…", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.callout)
                .help("Not receiving updates from your speakers. Trying to reconnect.")
        }
    }
}
