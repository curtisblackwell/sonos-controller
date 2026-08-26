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
    /// the thing that finds out - and `SetRelativeGroupVolume` deliberately does *not* clamp,
    /// since a negative adjustment is the whole point of it.
    @Test func volumeArgumentsAreClampedToTheSonosRange() {
        #expect(SonosSOAP.envelope(action: RenderingAction.setVolume(140)).contains("<DesiredVolume>100</DesiredVolume>"))
        #expect(SonosSOAP.envelope(action: RenderingAction.setVolume(-5)).contains("<DesiredVolume>0</DesiredVolume>"))
        #expect(SonosSOAP.envelope(action: GroupRenderingAction.setGroupVolume(200)).contains("<DesiredVolume>100</DesiredVolume>"))
        #expect(SonosSOAP.envelope(action: GroupRenderingAction.setRelativeGroupVolume(-6)).contains("<Adjustment>-6</Adjustment>"))
    }

    @Test func muteIsSentAsOneOrZero() {
        #expect(SonosSOAP.envelope(action: RenderingAction.setMute(true)).contains("<DesiredMute>1</DesiredMute>"))
        #expect(SonosSOAP.envelope(action: RenderingAction.setMute(false)).contains("<DesiredMute>0</DesiredMute>"))
        #expect(SonosSOAP.envelope(action: GroupRenderingAction.setGroupMute(true)).contains("<DesiredMute>1</DesiredMute>"))
    }

    /// A group has no stereo channels of its own, and sending one is how you get a 402 back.
    @Test func groupActionsTakeNoChannel() {
        let envelope = SonosSOAP.envelope(action: GroupRenderingAction.getGroupVolume)
        #expect(envelope.contains("<u:GetGroupVolume xmlns:u=\"urn:schemas-upnp-org:service:GroupRenderingControl:1\">"))
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
