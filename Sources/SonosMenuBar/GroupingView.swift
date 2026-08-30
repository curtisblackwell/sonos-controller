import SwiftUI

/// The full topology editor: every group in the household as a section, every room as a
/// draggable row with its own volume slider. Drag a room onto another group to join it, or
/// onto "On Their Own" to ungroup it. Every drag has a menu equivalent on the row, so the
/// editor is fully usable from the keyboard and with VoiceOver.
struct GroupingView: View {
    @ObservedObject var model: TopologyModel
    @ObservedObject var volume: VolumeModel
    @ObservedObject var playback: PlaybackModel

    private static let minWindowWidth: CGFloat = 960

    /// Tracks the window's actual width so the seek slider can scale with it. Starts at the
    /// window minimum so the very first layout pass - before GeometryReader reports a real
    /// size - already sizes the slider correctly instead of snapping once it does.
    @State private var windowWidth: CGFloat = GroupingView.minWindowWidth

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            footer
        }
        .frame(minWidth: Self.minWindowWidth, minHeight: 360)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { windowWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, newWidth in
                        windowWidth = newWidth
                    }
            }
        }
        .alert(
            "Grouping Failed",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            presenting: model.errorMessage
        ) { _ in
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.groups.isEmpty {
            ContentUnavailableView {
                Label("No Speakers Found", systemImage: "hifispeaker.and.homepod")
            } description: {
                Text("Make sure your Sonos speakers are on the same network, then refresh.")
            } actions: {
                Button("Look Again") { model.refresh() }
            }
        } else {
            List {
                ForEach(multiRoomGroups) { group in
                    groupSection(group)
                }
                standaloneSection
            }
            .listStyle(.sidebar)
            // Deliberately on the list rather than alongside the grouping alert on the
            // outer view: two alerts on one view is one alert, and whichever lost would
            // never be seen.
            .alert(
                "Couldn't Match Volumes",
                isPresented: Binding(
                    get: { volume.errorMessage != nil },
                    set: { if !$0 { volume.errorMessage = nil } }
                ),
                presenting: volume.errorMessage
            ) { _ in
                Button("OK", role: .cancel) { volume.errorMessage = nil }
            } message: { message in
                Text(message)
            }
            // The model refuses moves while one is in flight, since it would be deciding
            // against a topology that hasn't caught up yet. Disabling says so instead of
            // letting drops land on nothing.
            .disabled(model.isBusy)
        }
    }

    // MARK: - Sections

    /// Groups with more than one room get their own section. Rooms that are alone are
    /// collected into a single "On Their Own" section instead of one section each, which
    /// would otherwise dominate the list in a household with few groups.
    private var multiRoomGroups: [SonosGroup] {
        model.groups
            .filter { !$0.isStandalone }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var standaloneRooms: [SonosRoom] {
        model.groups
            .filter(\.isStandalone)
            .compactMap(\.members.first)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func groupSection(_ group: SonosGroup) -> some View {
        Section {
            groupVolumeRow(group)
            ForEach(group.members) { room in
                roomRow(room, in: group)
            }
        } header: {
            HStack {
                Text(group.displayName)
                Spacer()
                activeToggle(for: group)
            }
            // A section header is a real view, so it makes a dependable drop target;
            // the section itself is not one.
            .contentShape(.rect)
            .dropTarget(joining: group.id, model: model)
        }
    }

    private var standaloneSection: some View {
        Section("On Their Own") {
            ForEach(standaloneRooms) { room in
                roomRow(room, in: model.group(containing: room), showsActiveToggle: true)
            }
            // Always present, even when the section has rooms in it, so there is a stable
            // place to drop a room you want pulled out of its group.
            HStack {
                Image(systemName: "arrow.down.to.line")
                Text("Drop a room here to ungroup it")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .dropDestination(for: SonosRoom.self) { rooms, _ in
                guard let room = rooms.first else { return false }
                model.move(room: room, to: .standalone)
                return true
            }
        }
    }

    // MARK: - Rows

    /// Rows are both the drag source and a drop target: dropping one room onto another
    /// puts it in that room's group. Dropping onto a room that is on its own pairs the two.
    ///
    /// `showsActiveToggle` carries the star for rooms that are on their own. A lone room is
    /// still a group of one and can drive the media keys, but it has no section header of
    /// its own to hang the star off - without this it would be the one thing in the
    /// household the window couldn't select.
    private func roomRow(_ room: SonosRoom, in group: SonosGroup?, showsActiveToggle: Bool = false) -> some View {
        HStack(spacing: 8) {
            // Only the label is the drag source. `.draggable` on the whole row would take
            // the slider's own drag gesture with it, and grabbing the knob would start
            // moving the room instead of the volume.
            HStack(spacing: 6) {
                Text(room.name)
                if let group, group.id == room.uuid, !group.isStandalone {
                    Text("Coordinator")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
            .draggable(room)
            .frame(minWidth: 90)

            volumeControl(
                value: volume.volume(forRoom: room),
                isMuted: volume.isMuted(room: room),
                label: room.name,
                setVolume: { volume.setVolume($0, forRoom: room) },
                toggleMute: { volume.toggleMute(room: room) }
            )

            if showsActiveToggle, let group {
                activeToggle(for: group)
            }
            moveMenu(for: room, currentGroup: group)
        }
        .contentShape(.rect)
        .dropTarget(joining: group?.id ?? room.uuid, model: model)
    }

    /// The whole group's volume, which moves its members in proportion rather than flattening
    /// them - so this and the per-room sliders below it are different controls, not two ways
    /// to reach the same one.
    private func groupVolumeRow(_ group: SonosGroup) -> some View {
        HStack(spacing: 8) {
            Text("All Rooms")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(minWidth: 90, alignment: .leading)

            volumeControl(
                value: volume.volume(forGroup: group),
                isMuted: volume.isMuted(group: group),
                label: group.displayName,
                setVolume: { volume.setVolume($0, forGroup: group) },
                toggleMute: { volume.toggleMute(group: group) },
                // Every position of the drag is scaled from where the members were when it
                // started. Without that, each frame would rescale the result of the last one
                // and the rounding would grind the group out of balance.
                onEditingChanged: { editing in
                    if editing {
                        volume.beginGroupDrag(group)
                    } else {
                        volume.endGroupDrag(group)
                    }
                }
            )

            Button("Match Quietest") {
                volume.syncToQuietest(in: group)
            }
            .controlSize(.small)
            .disabled(volume.isSyncing)
            .help("Set every room in this group to the volume of its quietest one.")
        }
    }

    /// A mute button, a slider, and the number.
    ///
    /// `value` is nil until the first reading lands. A slider parked at zero would read as
    /// "this speaker is silent" rather than "not known yet", and dragging it up from there
    /// would write a volume nobody chose - so it stays disabled until there is a real number
    /// behind it.
    private func volumeControl(
        value: Int?,
        isMuted: Bool,
        label: String,
        setVolume: @escaping (Int) -> Void,
        toggleMute: @escaping () -> Void,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) -> some View {
        HStack(spacing: 6) {
            Button(action: toggleMute) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(isMuted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
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
            .frame(width: 110)
            .disabled(value == nil)
            .accessibilityLabel("\(label) volume")
            .accessibilityValue(value.map { "\($0) percent" } ?? "Not known yet")

            Text(value.map(String.init) ?? "—")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
    }

    /// The non-drag path to every destination a drag can reach.
    private func moveMenu(for room: SonosRoom, currentGroup: SonosGroup?) -> some View {
        Menu {
            Button("On Its Own") {
                model.move(room: room, to: .standalone)
            }
            .disabled(currentGroup?.isStandalone == true)

            Divider()

            ForEach(joinableGroups(for: room)) { group in
                Button("Join \(group.displayName)") {
                    model.move(room: room, to: .group(coordinatorUUID: group.id))
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Move \(room.name)")
    }

    /// Every group the room isn't already in. A standalone room shows up here too - joining
    /// it is how you build a new pair.
    private func joinableGroups(for room: SonosRoom) -> [SonosGroup] {
        model.groups
            .filter { $0.id != model.group(containing: room)?.id }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private func activeToggle(for group: SonosGroup) -> some View {
        Button {
            model.setActiveGroup(group)
        } label: {
            Image(systemName: model.activeGroupID == group.id ? "star.fill" : "star")
                .foregroundStyle(model.activeGroupID == group.id ? .yellow : .secondary)
        }
        .buttonStyle(.plain)
        .help(group.isStandalone ? "Send media key presses to this speaker" : "Send media key presses to this group")
        .accessibilityLabel(
            model.activeGroupID == group.id
                ? "\(group.displayName) receives media keys"
                : "Send media keys to \(group.displayName)"
        )
    }

    // MARK: - Footer

    private var footer: some View {
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
        // Fixed rather than left to size to content, so the footer doesn't grow or shrink
        // as playback state comes and goes - the transport row above disappears entirely
        // with no active group, and the row heights alone wouldn't hold the gap open.
        .frame(height: 84)
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
            .frame(width: max(400, windowWidth * 2 / 3))
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

    private static func formatPlaybackTime(_ seconds: Int) -> String {
        let seconds = max(seconds, 0)
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// The household's own volume row, one rung up from `groupVolumeRow`: every room in every
    /// group, moved in the same proportion. Paired with the same "match to quietest" action a
    /// group row offers, just aimed at the whole household.
    @ViewBuilder
    private var householdVolumeRow: some View {
        if !model.groups.isEmpty {
            HStack(spacing: 8) {
                volumeControl(
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

private extension View {
    /// Accepts a dropped room into the group coordinated by `coordinatorUUID`.
    ///
    /// One room per drop. The list has no multi-selection, so a drag never carries more than
    /// one - and looping over them would only look like it handled several: the model refuses
    /// a second move while the first is in flight, so every room after the first was silently
    /// dropped on the floor.
    func dropTarget(joining coordinatorUUID: String, model: TopologyModel) -> some View {
        dropDestination(for: SonosRoom.self) { rooms, _ in
            guard let room = rooms.first else { return false }
            model.move(room: room, to: .group(coordinatorUUID: coordinatorUUID))
            return true
        }
    }
}
