import SwiftUI

/// A mute button, a slider, and the number. Shared by every rung of the volume hierarchy -
/// room rows and group rows on the Speakers page, and the household row in the now-playing
/// bar - so the three read and behave identically.
///
/// `value` is nil until the first reading lands. A slider parked at zero would read as
/// "this speaker is silent" rather than "not known yet", and dragging it up from there
/// would write a volume nobody chose - so it stays disabled until there is a real number
/// behind it.
struct VolumeSlider: View {
    let value: Int?
    let isMuted: Bool
    let label: String
    let setVolume: (Int) -> Void
    let toggleMute: () -> Void
    /// Group and household sliders scale their members from where they were when the drag
    /// started, so they need to know when one begins and ends. Room sliders write directly
    /// and have nothing to do here.
    var onEditingChanged: (Bool) -> Void = { _ in }
    /// Room and group rows size themselves to a fixed 110pt so many stacked rows line up.
    /// The header passes nil so the slider stretches to fill whatever width the row is
    /// given, matching the Spotify search field above it regardless of icon sizing.
    var sliderWidth: CGFloat? = 110

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleMute) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(isMuted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .disabled(value == nil)
            .help(isMuted ? "Unmute \(label)" : "Mute \(label)")
            .accessibilityLabel(isMuted ? "Unmute \(label)" : "Mute \(label)")

            Slider(
                value: Binding(
                    get: { Double(value ?? 0) },
                    set: { setVolume(Int($0.rounded())) }
                ),
                in: Double(VolumeControl.range.lowerBound)...Double(VolumeControl.range.upperBound),
                onEditingChanged: onEditingChanged
            )
            .frame(maxWidth: sliderWidth ?? .infinity)
            .disabled(value == nil)
            .accessibilityLabel("\(label) volume")
            .accessibilityValue(value.map { "\($0) percent" } ?? "Not known yet")

            Text(value.map(String.init) ?? "—")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
    }
}
