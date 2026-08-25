import Foundation
import os.log

enum SonosAction: String {
    case play = "Play"
    case pause = "Pause"
    case next = "Next"
    case previous = "Previous"
    case getTransportInfo = "GetTransportInfo"
}

enum SonosControl {
    private static let log = Logger(subsystem: "com.curtis.sonos-controller", category: "control")

    static func soapEnvelope(action: SonosAction) -> String {
        let extra: String
        switch action {
        case .play: extra = "<Speed>1</Speed>"
        case .pause, .next, .previous, .getTransportInfo: extra = ""
        }
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body><u:\(action.rawValue) xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID>\(extra)</u:\(action.rawValue)></s:Body>
        </s:Envelope>
        """
    }

    static func controlURL(ip: String) -> URL? {
        URL(string: "http://\(ip):1400/MediaRenderer/AVTransport/Control")
    }

    static func send(action: SonosAction, to ip: String, completion: ((Data?) -> Void)? = nil) {
        guard let url = controlURL(ip: ip) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#\(action.rawValue)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(soapEnvelope(action: action).utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                log.error("Sonos \(action.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                log.error("Sonos \(action.rawValue, privacy: .public) returned HTTP \(http.statusCode)")
            }
            completion?(data)
        }.resume()
    }

    static func currentTransportState(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let start = text.range(of: "<CurrentTransportState>"),
              let end = text.range(of: "</CurrentTransportState>") else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }

    /// Toggling needs to know the current state, and there is no "toggle" UPnP action.
    /// If GetTransportInfo fails or comes back unparseable we do nothing rather than
    /// assume "not playing" - guessing turns a dropped packet mid-playback into a Play,
    /// so the pause press appears to be ignored.
    static func togglePlayPause(ip: String) {
        send(action: .getTransportInfo, to: ip) { data in
            guard let state = data.flatMap(currentTransportState) else {
                log.error("Could not read transport state from \(ip, privacy: .public), ignoring play/pause")
                return
            }
            let isPlaying = state == "PLAYING" || state == "TRANSITIONING"
            send(action: isPlaying ? .pause : .play, to: ip)
        }
    }
}
