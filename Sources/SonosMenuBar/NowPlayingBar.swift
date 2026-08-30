import SwiftUI

/// Lets the live-indicator icon lock its vertical center to the progress row's center,
/// instead of the whole footer's, even though the two sit in separate columns.
private struct ProgressRowAlignment: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat {
        context[VerticalAlignment.center]
    }
}

private extension VerticalAlignment {
    static let progressRowCenter = VerticalAlignment(ProgressRowAlignment.self)
}

/// The persistent bar along the bottom of the window: the transport, the seek slider, and
/// whether we're still hearing from the household.
///
/// It sits below the whole split view rather than inside the detail column, because none of
/// it is about the page you happen to be looking at - the active group and its playback are
/// the same wherever you are.
struct NowPlayingBar: View {
    @ObservedObject var model: TopologyModel
    @ObservedObject var playback: PlaybackModel

    /// Tracks the bar's own width so the seek slider can scale with the window. Starts at the
    /// window minimum so the very first layout pass - before GeometryReader reports a real
    /// size - already sizes the slider correctly instead of snapping once it does.
    @State private var barWidth: CGFloat = MainWindowView.minWindowWidth

    var body: some View {
        HStack(alignment: .progressRowCenter, spacing: 16) {
            Spacer(minLength: 12)
            VStack(spacing: 6) {
                transportControls
                progressRow
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
        .frame(height: 64)
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
        .alignmentGuide(.progressRowCenter) { $0[VerticalAlignment.center] }
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

    /// Only shown once there's an active group to target - matches the star toggle that
    /// picks one, and the media keys these buttons mirror.
    /// Bar content height (84 total minus 8pt top/bottom padding) minus the progress row and
    /// the spacing above it - what's left is what the transport buttons get to fill.
    private static let transportRowHeight: CGFloat = 22

    @ViewBuilder
    private var transportControls: some View {
        if model.activeGroupID != nil {
            HStack(alignment: .center, spacing: 14) {
                transportButton(systemImage: "backward.end.fill", help: "Previous Track", height: Self.transportRowHeight * 0.75) {
                    playback.previous()
                }
                transportButton(
                    systemImage: playback.isPlaying == true ? "pause.fill" : "play.fill",
                    help: playback.isPlaying == true ? "Pause" : "Play",
                    height: Self.transportRowHeight
                ) {
                    playback.togglePlayPause()
                }
                .disabled(playback.isPlaying == nil)
                transportButton(systemImage: "forward.end.fill", help: "Next Track", height: Self.transportRowHeight * 0.75) {
                    playback.next()
                }
            }
        }
    }

    private func transportButton(systemImage: String, help: String, height: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .resizable()
                .scaledToFit()
                .frame(width: height, height: height)
        }
        .buttonStyle(.plain)
        .frame(width: height, height: height)
        .help(help)
        .accessibilityLabel(help)
    }

    /// Replaces what used to be a Refresh button. The household pushes its changes now, and
    /// the subscription repairs itself, so there is nothing left for the user to trigger -
    /// what they actually need to know is whether what they're looking at is current. The
    /// status itself only shows on hover now, so the bar doesn't carry a permanent line of
    /// text for something that's true almost all the time.
    private var liveIndicator: some View {
        Group {
            if model.isReceivingLiveUpdates {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .font(.callout)
        .help(liveIndicatorTooltip)
        .quickTooltip(liveIndicatorTooltip)
        .alignmentGuide(.progressRowCenter) { $0[VerticalAlignment.center] }
    }

    private var liveIndicatorTooltip: String {
        model.isReceivingLiveUpdates
            ? "Connected to Sonos"
            : "Reconnecting…"
    }
}

/// `.help()`'s tooltip follows the system's ~1.5s hover delay with no way to shorten it, so
/// this shows the same text itself after a much shorter hover - `.help()` stays alongside it
/// only for VoiceOver's accessibility hint.
private struct QuickTooltipModifier: ViewModifier {
    let text: String

    @State private var showsTooltip = false
    @State private var hoverTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { isHovering in
                hoverTask?.cancel()
                if isHovering {
                    hoverTask = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        if !Task.isCancelled { showsTooltip = true }
                    }
                } else {
                    showsTooltip = false
                }
            }
            // Trailing rather than centered: this sits near the window's right edge, and a
            // centered bubble would grow half past it and get clipped there.
            .overlay(alignment: .topTrailing) {
                if showsTooltip {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .fixedSize(horizontal: true, vertical: false)
                        .offset(y: -28)
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
    }
}

private extension View {
    func quickTooltip(_ text: String) -> some View {
        modifier(QuickTooltipModifier(text: text))
    }
}
