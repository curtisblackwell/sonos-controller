import Testing
import Foundation
@testable import SonosMenuBar

struct SOAPEnvelopeTests {
    @Test func playEnvelopeIncludesSpeed() {
        let envelope = SonosControl.soapEnvelope(action: .play)
        #expect(envelope.contains("<u:Play xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"))
        #expect(envelope.contains("<Speed>1</Speed>"))
        #expect(envelope.contains("<InstanceID>0</InstanceID>"))
    }

    @Test func pauseEnvelopeHasNoExtraElement() {
        let envelope = SonosControl.soapEnvelope(action: .pause)
        #expect(envelope.contains("<u:Pause"))
        #expect(!envelope.contains("<Speed>"))
    }

    @Test func nextAndPreviousActionNames() {
        #expect(SonosControl.soapEnvelope(action: .next).contains("<u:Next"))
        #expect(SonosControl.soapEnvelope(action: .previous).contains("<u:Previous"))
    }

    @Test func controlURL() {
        #expect(SonosControl.controlURL(ip: "192.168.1.50")?.absoluteString ==
                 "http://192.168.1.50:1400/MediaRenderer/AVTransport/Control")
    }

    @Test func parsesCurrentTransportStatePlaying() {
        let body = "<CurrentTransportState>PLAYING</CurrentTransportState>"
        #expect(SonosControl.currentTransportState(from: Data(body.utf8)) == "PLAYING")
    }

    @Test func parsesCurrentTransportStatePaused() {
        let body = "<CurrentTransportState>PAUSED_PLAYBACK</CurrentTransportState>"
        #expect(SonosControl.currentTransportState(from: Data(body.utf8)) == "PAUSED_PLAYBACK")
    }
}
