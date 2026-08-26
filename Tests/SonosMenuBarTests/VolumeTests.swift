import CoreGraphics
import Foundation
import Testing
@testable import SonosMenuBar

struct VolumeEnvelopeTests {
    @Test func setVolumeCarriesMasterChannelAndValue() {
        let envelope = SonosSOAP.envelope(action: RenderingAction.setVolume(37))
        #expect(envelope.contains("<u:SetVolume xmlns:u=\"urn:schemas-upnp-org:service:RenderingControl:1\">"))
        #expect(envelope.contains("<InstanceID>0</InstanceID>"))
        #expect(envelope.contains("<Channel>Master</Channel>"))
        #expect(envelope.contains("<DesiredVolume>37</DesiredVolume>"))
    }

    /// The speaker would clamp anyway, but a slider that briefly reported 104 shouldn't be
    /// the thing that finds out.
    @Test func volumeArgumentsAreClampedToTheSonosRange() {
        #expect(SonosSOAP.envelope(action: RenderingAction.setVolume(140)).contains("<DesiredVolume>100</DesiredVolume>"))
        #expect(SonosSOAP.envelope(action: RenderingAction.setVolume(-5)).contains("<DesiredVolume>0</DesiredVolume>"))
    }

    @Test func muteIsSentAsOneOrZero() {
        #expect(SonosSOAP.envelope(action: RenderingAction.setMute(true)).contains("<DesiredMute>1</DesiredMute>"))
        #expect(SonosSOAP.envelope(action: RenderingAction.setMute(false)).contains("<DesiredMute>0</DesiredMute>"))
        #expect(SonosSOAP.envelope(action: GroupRenderingAction.setGroupMute(true)).contains("<DesiredMute>1</DesiredMute>"))
    }

    /// A group has no stereo channels of its own, and sending one is how you get a 402 back.
    @Test func groupActionsTakeNoChannel() {
        let envelope = SonosSOAP.envelope(action: GroupRenderingAction.getGroupMute)
        #expect(envelope.contains("<u:GetGroupMute xmlns:u=\"urn:schemas-upnp-org:service:GroupRenderingControl:1\">"))
        #expect(envelope.contains("<InstanceID>0</InstanceID>"))
        #expect(!envelope.contains("<Channel>"))
    }

    @Test func eachServiceHasItsOwnControlEndpoint() {
        #expect(SonosService.renderingControl.controlURL(ip: "192.168.1.50")?.absoluteString ==
                "http://192.168.1.50:1400/MediaRenderer/RenderingControl/Control")
        #expect(SonosService.groupRenderingControl.controlURL(ip: "192.168.1.50")?.absoluteString ==
                "http://192.168.1.50:1400/MediaRenderer/GroupRenderingControl/Control")
        #expect(SonosService.avTransport.controlURL(ip: "192.168.1.50")?.absoluteString ==
                "http://192.168.1.50:1400/MediaRenderer/AVTransport/Control")
    }
}

struct SOAPValueTests {
    @Test func readsAnOutArgument() {
        let body = Data("<s:Body><u:GetVolumeResponse><CurrentVolume>42</CurrentVolume></u:GetVolumeResponse></s:Body>".utf8)
        #expect(SonosSOAP.intValue(named: "CurrentVolume", in: body) == 42)
    }

    @Test func missingArgumentReadsAsNothing() {
        let body = Data("<s:Body><u:SetVolumeResponse></u:SetVolumeResponse></s:Body>".utf8)
        #expect(SonosSOAP.intValue(named: "CurrentVolume", in: body) == nil)
    }

    /// The closing tag ahead of the opening one makes the range run backwards, which traps
    /// when sliced rather than returning nothing.
    @Test func aBodyWithTheTagsTheWrongWayRoundReadsAsNothing() {
        let body = Data("</CurrentVolume>42<CurrentVolume>".utf8)
        #expect(SonosSOAP.value(named: "CurrentVolume", in: body) == nil)
    }
}

struct GroupScalingTests {
    private func room(_ uuid: String, _ name: String, _ ip: String) -> SonosRoom {
        SonosRoom(uuid: uuid, name: name, ipAddress: ip)
    }

    /// The bug this whole path exists for: `GroupRenderingControl` answers a nudge on a level
    /// group by fanning it back out to a balance it remembers from before. Scaling by ratio
    /// leaves a level group level.
    @Test func alevelGroupStaysLevel() {
        let targets = VolumeModel.memberTargets(
            baseline: ["a": 7, "b": 7, "c": 7, "d": 7],
            movingFrom: 7,
            to: 13
        )
        #expect(targets == ["a": 13, "b": 13, "c": 13, "d": 13])
    }

    @Test func membersKeepTheirShareOfAnUnevenGroup() {
        // Mean of 22 and 34 is 28; asking for 42 is a ratio of 1.5.
        let targets = VolumeModel.memberTargets(baseline: ["a": 22, "b": 34], movingFrom: 28, to: 42)
        #expect(targets == ["a": 33, "b": 51])
    }

    /// Partway through a drag the speakers are nowhere near the baseline, so a position that
    /// happens to equal the one the drag started at still has to be written - otherwise
    /// pulling the slider back to where you picked it up leaves the group where it was.
    @Test func returningToTheBaselineRestoresIt() {
        #expect(VolumeModel.memberTargets(baseline: ["a": 40, "b": 20], movingFrom: 30, to: 30) == ["a": 40, "b": 20])
    }

    /// A speaker quiet enough that the ratio rounds it onto itself is still reported; the
    /// caller drops the write after comparing with what the speaker is currently at.
    @Test func everyMemberIsAccountedFor() {
        let targets = VolumeModel.memberTargets(baseline: ["a": 1, "b": 59], movingFrom: 30, to: 31)
        #expect(targets == ["a": 1, "b": 61])
    }

    /// Zero has no ratio - every member is 0, and scaling would pin the group there forever.
    @Test func aGroupScaledToSilenceCanStillComeBack() {
        #expect(VolumeModel.memberTargets(baseline: ["a": 30, "b": 50], movingFrom: 40, to: 0) == ["a": 0, "b": 0])
        #expect(VolumeModel.memberTargets(baseline: ["a": 0, "b": 0], movingFrom: 0, to: 12) == ["a": 12, "b": 12])
        #expect(VolumeModel.memberTargets(baseline: ["a": 0, "b": 0], movingFrom: 0, to: 0) == ["a": 0, "b": 0])
    }

    @Test func targetsAreClampedPerMember() {
        let targets = VolumeModel.memberTargets(baseline: ["a": 60, "b": 90], movingFrom: 75, to: 100)
        #expect(targets["a"] == 80)
        #expect(targets["b"] == 100)
    }

    /// A group slider can only be moved once every member has answered: an average over the
    /// rooms that did would be a baseline that doesn't describe the group, and the first
    /// nudge would scale the silent ones by the wrong ratio.
    @Test func groupVolumeNeedsEveryMember() {
        let rooms = [room("a", "Kitchen", "192.168.1.1"), room("b", "Office", "192.168.1.2")]
        #expect(VolumeModel.averageVolume(of: rooms, in: ["a": 20, "b": 30]) == 25)
        #expect(VolumeModel.averageVolume(of: rooms, in: ["a": 20]) == nil)
        #expect(VolumeModel.averageVolume(of: [], in: ["a": 20]) == nil)
    }

    /// Sonos rounds the same way: 22/34/37/27 reads back as a group volume of 30.
    @Test func groupVolumeIsTheRoundedMean() {
        let rooms = [room("a", "Roam", "1"), room("b", "Living Room", "2"), room("c", "Bedroom", "3"), room("d", "Office", "4")]
        #expect(VolumeModel.averageVolume(of: rooms, in: ["a": 22, "b": 34, "c": 37, "d": 27]) == 30)
    }
}

struct QuietestSyncTests {
    @Test func picksTheLowestAndOnlyWritesTheRoomsAboveIt() {
        let plan = VolumeModel.quietestSync(volumes: ["a": 40, "b": 12, "c": 25])
        #expect(plan?.volume == 12)
        #expect(plan?.rooms == ["a", "c"])
    }

    /// Nothing to do has to be distinguishable from something to do: a caller that showed
    /// progress for an empty plan would have nothing to clear it.
    @Test func alreadyMatchedIsNoPlanAtAll() {
        #expect(VolumeModel.quietestSync(volumes: ["a": 20, "b": 20]) == nil)
    }

    @Test func oneReadingCannotBeSyncedToAnything() {
        #expect(VolumeModel.quietestSync(volumes: ["a": 20]) == nil)
        #expect(VolumeModel.quietestSync(volumes: [:]) == nil)
    }

    /// Rooms that didn't answer are simply absent from the readings - the plan must be made
    /// from what came back, never from a zero standing in for a speaker we couldn't reach.
    @Test func onlyRoomsThatAnsweredAreConsidered() {
        let plan = VolumeModel.quietestSync(volumes: ["a": 55, "b": 30])
        #expect(plan?.volume == 30)
        #expect(plan?.rooms == ["a"])
    }
}

struct VolumeKeyModifierTests {
    /// Shift alone is ours. Shift-Option opens Sound settings and Command picks the output
    /// device; taking either would replace a system shortcut with one nobody asked for.
    @Test func onlyShiftAloneClaimsTheVolumeKeys() {
        #expect(MediaKeyTap.isShiftOnly([.maskShift]))
        #expect(MediaKeyTap.isShiftOnly([.maskShift, .maskAlphaShift]))
        #expect(!MediaKeyTap.isShiftOnly([]))
        #expect(!MediaKeyTap.isShiftOnly([.maskShift, .maskAlternate]))
        #expect(!MediaKeyTap.isShiftOnly([.maskShift, .maskCommand]))
        #expect(!MediaKeyTap.isShiftOnly([.maskShift, .maskControl]))
    }
}
