import SwiftUI

/// The bar across the top of the window: what's playing, and the household volume.
///
/// Sits outside the split view for the same reason `NowPlayingBar` does - the active
/// group's track and the household volume don't change when you switch pages.
struct HeaderBar: View {
    @ObservedObject var model: TopologyModel
    @ObservedObject var volume: VolumeModel
    @ObservedObject var playback: PlaybackModel
    @ObservedObject var spotifySearch: SpotifySearchModel
    @ObservedObject var spotifyAuth: SpotifyAuth
    @Binding var selection: SidebarItem?

    /// Total outer width shared by the search field and the household volume row, so mute
    /// button + slider + number line up with the search box's edges rather than just the
    /// slider matching the text field's inner width.
    private let headerControlWidth: CGFloat = 220

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            nowPlaying
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                spotifySearchField
                householdVolumeRow
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Searches Spotify from anywhere in the app, not just the Spotify page - submitting jumps
    /// the sidebar to `.spotify` so the results are visible. Hidden rather than disabled when
    /// signed out, since there's nothing useful to search yet.
    @ViewBuilder
    private var spotifySearchField: some View {
        if spotifyAuth.isAuthenticated {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Spotify", text: $spotifySearch.filter)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        selection = .spotify
                        spotifySearch.search()
                    }
                if !spotifySearch.filter.isEmpty {
                    Button {
                        spotifySearch.filter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear filter")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .frame(width: headerControlWidth)
        }
    }

    /// Album art and title/artist/album for whatever `playback` is currently reading. Reads
    /// as "Nothing Playing" rather than disappearing when there's no active group or no
    /// track - `PlaybackModel` already reports that as `track == nil`.
    private var nowPlaying: some View {
        HStack(spacing: 12) {
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
        RoundedRectangle(cornerRadius: 6)
            .fill(.quaternary)
            .frame(width: 108, height: 108)
            .overlay {
                if let url = playback.track?.albumArtURL {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Image(systemName: "music.note").foregroundStyle(.secondary)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            }
    }

    /// The household's own volume row, one rung up from the group sliders on the Speakers
    /// page: every room in every group, moved in the same proportion. Paired with the same
    /// "match to quietest" action a group row offers, just aimed at the whole household.
    @ViewBuilder
    private var householdVolumeRow: some View {
        if !model.groups.isEmpty {
            VStack(alignment: .trailing, spacing: 6) {
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
                    },
                    sliderWidth: nil
                )
                .frame(width: headerControlWidth)

                Button("Match Quietest") {
                    volume.syncEverythingToQuietest()
                }
                .controlSize(.small)
                .disabled(volume.isSyncing)
                .help("Set every speaker in the house to the volume of the quietest one.")
            }
        }
    }
}
