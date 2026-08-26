import SwiftUI

/// The full topology editor: every group in the household as a section, every room as a
/// draggable row. Drag a room onto another group to join it, or onto "On Their Own" to
/// ungroup it. Every drag has a menu equivalent on the row, so the editor is fully usable
/// from the keyboard and with VoiceOver.
struct GroupingView: View {
    @ObservedObject var model: TopologyModel

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            footer
        }
        .frame(minWidth: 380, minHeight: 320)
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
                Button("Refresh") { model.refresh() }
            }
        } else {
            List {
                ForEach(multiRoomGroups) { group in
                    groupSection(group)
                }
                standaloneSection
            }
            .listStyle(.sidebar)
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
        HStack {
            Text(room.name)
            if let group, group.id == room.uuid, !group.isStandalone {
                Text("Coordinator")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if showsActiveToggle, let group {
                activeToggle(for: group)
            }
            moveMenu(for: room, currentGroup: group)
        }
        .contentShape(.rect)
        .draggable(room)
        .dropTarget(joining: group?.id ?? room.uuid, model: model)
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
        HStack {
            if model.isBusy {
                ProgressView().controlSize(.small)
                Text("Updating…").foregroundStyle(.secondary).font(.callout)
            }
            Spacer()
            Button("Refresh") { model.refresh() }
                .disabled(model.isBusy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
