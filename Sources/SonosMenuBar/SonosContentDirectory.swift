import Foundation
import os.log

/// A ContentDirectory action. Unlike the MediaRenderer services, none of these take an
/// `InstanceID` - the service belongs to the player, not to a playback instance.
enum ContentDirectoryAction: SonosSOAPAction {
    /// `objectID` is a Sonos ObjectID: `FV:2` for favorites, `SQ:` for Sonos playlists,
    /// `SQ:<n>` for one playlist's tracks, `Q:0` for the queue, `A:ARTIST` and friends for the
    /// local library index.
    ///
    /// Note that `Search` is deliberately absent: Sonos does not implement the UPnP `Search`
    /// action at all, and `GetSearchCapabilities` comes back empty. Filtering a browsed list
    /// in-process is the only search there is for favorites, playlists, and the queue.
    case browse(objectID: String, start: Int, count: Int)

    var service: SonosService { .contentDirectory }
    var includesInstanceID: Bool { false }

    var name: String {
        switch self {
        case .browse: return "Browse"
        }
    }

    var arguments: [(name: String, value: String)] {
        switch self {
        case let .browse(objectID, start, count):
            return [
                ("ObjectID", objectID),
                ("BrowseFlag", "BrowseDirectChildren"),
                ("Filter", "*"),
                ("StartingIndex", String(start)),
                ("RequestedCount", String(count)),
                ("SortCriteria", ""),
            ]
        }
    }
}

/// Reads the household's own content: favorites, Sonos playlists, the queue, the local
/// library. Everything here works without any music-service credentials, because the player
/// already holds them - a favorite carries the URI and metadata needed to play it, whichever
/// service it came from.
enum SonosContentDirectory {
    private static let log = Logger(subsystem: "com.curtisblackwell.sonos-controller", category: "content-directory")

    /// Well-known ObjectIDs.
    enum ObjectID {
        static let favorites = "FV:2"
        static let sonosPlaylists = "SQ:"
        static let queue = "Q:0"
        static let radioStations = "R:0/0"
    }

    /// `RequestedCount` is capped at 1000 by the service, and 0 is interpreted as 1000 rather
    /// than "no limit". Paging in smaller batches keeps any one response small enough to parse
    /// quickly and lets a large library surface its first screen sooner.
    private static let pageSize = 200

    /// Every child of `objectID`, following `TotalMatches` across as many requests as it
    /// takes. Completion runs on a URLSession queue, not the main thread.
    static func browseAll(
        objectID: String,
        from ip: String,
        completion: @escaping (Result<[MediaItem], Error>) -> Void
    ) {
        browsePage(objectID: objectID, from: ip, start: 0, collected: [], completion: completion)
    }

    private static func browsePage(
        objectID: String,
        from ip: String,
        start: Int,
        collected: [MediaItem],
        completion: @escaping (Result<[MediaItem], Error>) -> Void
    ) {
        SonosSOAP.send(action: ContentDirectoryAction.browse(objectID: objectID, start: start, count: pageSize), to: ip) { result in
            switch result {
            case let .failure(error):
                log.error("Browse \(objectID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                completion(.failure(error))
            case let .success(data):
                let page = items(fromBrowseResponse: data, coordinatorIP: ip)
                let total = SonosSOAP.intValue(named: "TotalMatches", in: data) ?? 0
                let all = collected + page
                // Stop on an empty page as well as on the count: a TotalMatches that
                // overreports (or a container that shrinks mid-walk) would otherwise loop
                // forever asking for children that aren't coming.
                guard !page.isEmpty, all.count < total else {
                    completion(.success(all))
                    return
                }
                browsePage(objectID: objectID, from: ip, start: all.count, collected: all, completion: completion)
            }
        }
    }

    /// Pulls the DIDL-Lite document out of a `Browse` response and parses it.
    ///
    /// Two stages, the same shape as `SonosTopology`'s handling of `ZoneGroupState`: the
    /// payload arrives as escaped XML inside `<Result>`, so one parse extracts it as text and
    /// a second parses the document that text turns out to be.
    static func items(fromBrowseResponse data: Data, coordinatorIP: String) -> [MediaItem] {
        let extractor = ElementTextExtractor(elementName: "Result")
        let parser = XMLParser(data: data)
        parser.delegate = extractor
        guard parser.parse(), !extractor.text.isEmpty else { return [] }
        return DIDL.items(inDocument: extractor.text, coordinatorIP: coordinatorIP)
    }
}

/// Accumulates the text of one named element. `Browse` wraps its payload in `<Result>` the way
/// ZoneGroupTopology wraps the topology in `<ZoneGroupState>`, and in both cases XMLParser
/// hands the text back already unescaped once - which is exactly the inner document.
final class ElementTextExtractor: NSObject, XMLParserDelegate {
    private(set) var text = ""
    private let elementName: String
    private var capturing = false

    init(elementName: String) {
        self.elementName = elementName
        super.init()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == self.elementName { capturing = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == self.elementName { capturing = false }
    }
}

/// DIDL-Lite: the metadata format Sonos speaks for everything that can be played.
enum DIDL {
    /// ObjectID prefixes whose *children* can themselves be opened: a Sonos playlist expands
    /// into its tracks, a local-library category into albums and then tracks.
    ///
    /// `FV:` and `Q:` are deliberately absent even though both are browsable as roots. Their
    /// rows are leaves: a favorite (`FV:2/30`) names a music-service container the player will
    /// not enumerate, and browsing the favorite's own id returns an empty list rather than the
    /// album's tracks; a queue row (`Q:0/1`) is a single track. Those roots reach `Browse`
    /// because the sidebar names them, not because a row claimed to expand.
    private static let browsablePrefixes = ["SQ:", "A:", "S:"]

    /// Parses a DIDL-Lite document into rows. `<item>` and `<container>` are both accepted;
    /// which one an entry used is what distinguishes a track from something you might be able
    /// to open.
    static func items(inDocument xml: String, coordinatorIP: String) -> [MediaItem] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        let delegate = DIDLParser(coordinatorIP: coordinatorIP)
        parser.delegate = delegate
        guard parser.parse() else { return [] }
        return delegate.items
    }

    /// Sonos gives `upnp:albumArtURI` as an absolute URL when the art lives with the service,
    /// and as a path relative to the player serving it (`/getaa?...`) when the player is
    /// proxying it.
    static func artURL(from raw: String?, coordinatorIP: String) -> URL? {
        guard let raw else { return nil }
        let unescaped = SonosSOAP.xmlUnescaped(raw)
        if unescaped.hasPrefix("http://") || unescaped.hasPrefix("https://") {
            return URL(string: unescaped)
        }
        // Deliberately not percent-encoded: the path Sonos gives is already encoded
        // (`/getaa?s=1&u=x-sonos-spotify%3aspotify%253atrack%253a…`), so encoding it again
        // would turn every `%` into `%25` and produce a URL the player rejects.
        return URL(string: "http://\(coordinatorIP):1400\(unescaped)")
    }

    /// Whether browsing this ObjectID will return children, or only an error.
    ///
    /// A favorite is an `<item>` even when it points at a playlist, so this correctly says no
    /// for one: the container it names belongs to a music service and cannot be enumerated,
    /// and browsing the favorite's own id comes back empty.
    static func canExpand(id: String, isContainer: Bool) -> Bool {
        isContainer && browsablePrefixes.contains { id.hasPrefix($0) }
    }

    /// The music service id from a playback URI's query, e.g. 12 from
    /// `x-sonos-spotify:spotify%3atrack%3a…?sid=12&flags=8232&sn=13`.
    static func serviceID(inPlayURI uri: String) -> Int? {
        queryValue(named: "sid", inPlayURI: uri).flatMap(Int.init)
    }

    /// The account serial number from a playback URI's query - `sn=13` above.
    ///
    /// Worth having because it is the only remaining source of the value: constructing a URI
    /// for a service track needs the account serial, and the `/status/accounts` endpoint that
    /// used to report it returns an empty document on current firmware. Reading it back off
    /// content the household already has is the way to learn it.
    static func accountSerial(inPlayURI uri: String) -> String? {
        queryValue(named: "sn", inPlayURI: uri)
    }

    /// These URIs are not parseable by `URLComponents` - the part before `?` is an
    /// unencoded, colon-laden service id - so the query is read directly.
    private static func queryValue(named name: String, inPlayURI uri: String) -> String? {
        guard let queryStart = uri.firstIndex(of: "?") else { return nil }
        let query = uri[uri.index(after: queryStart)...]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0] == name else { continue }
            return String(parts[1])
        }
        return nil
    }
}

/// Walks one DIDL-Lite document.
///
/// `r:resMD` needs care: it holds a whole nested DIDL-Lite document, escaped, and it is the
/// metadata a favorite must be played with - it carries the `<desc id="cdudn">` credential
/// token that tells the player which linked account to use. XMLParser hands escaped markup
/// back through `foundCharacters` as plain text and unescapes it exactly once, which is the
/// form Sonos wants it in, so accumulating those characters verbatim is both simplest and
/// correct.
private final class DIDLParser: NSObject, XMLParserDelegate {
    private(set) var items: [MediaItem] = []
    private let coordinatorIP: String

    /// Fields of the entry currently open. Reset on every `<item>`/`<container>`.
    private var id = ""
    private var isContainer = false
    private var text: [String: String] = [:]
    private var currentElement: String?
    private var depth = 0

    init(coordinatorIP: String) {
        self.coordinatorIP = coordinatorIP
        super.init()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        // qName keeps the prefix (`dc:title`), which is how these fields are named
        // everywhere else in the app; elementName drops it.
        let name = qName ?? elementName
        if name == "item" || name == "container" {
            depth = 1
            id = attributeDict["id"] ?? ""
            isContainer = name == "container"
            text = [:]
            currentElement = nil
            return
        }
        guard depth > 0 else { return }
        depth += 1
        currentElement = name
        // `<res>` carries the duration as an attribute rather than as text.
        if name == "res", let duration = attributeDict["duration"] {
            text["res@duration"] = duration
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let currentElement, depth > 0 else { return }
        text[currentElement, default: ""] += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = qName ?? elementName
        if name == "item" || name == "container" {
            appendCurrentEntry()
            depth = 0
            currentElement = nil
            return
        }
        guard depth > 0 else { return }
        depth -= 1
        currentElement = nil
    }

    private func appendCurrentEntry() {
        let title = text["dc:title"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty || !title.isEmpty else { return }

        let playURI = text["res"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let upnpClass = text["upnp:class"] ?? ""
        // A favorite is an <item> whose class says otherwise, and the class is what the UI
        // should believe when deciding whether to draw this as an album or a song.
        let looksLikeContainer = isContainer || upnpClass.contains("object.container")

        items.append(
            MediaItem(
                id: id,
                title: title,
                subtitle: subtitle,
                artURL: DIDL.artURL(from: text["upnp:albumArtURI"], coordinatorIP: coordinatorIP),
                playURI: playURI?.isEmpty == true ? nil : playURI,
                // `r:resMD` is the metadata to play a favorite with. Its absence is normal for
                // a queue track, which the player can play from the URI alone.
                playMetadata: text["r:resMD"],
                isContainer: looksLikeContainer,
                canExpand: DIDL.canExpand(id: id, isContainer: looksLikeContainer),
                serviceID: playURI.flatMap(DIDL.serviceID(inPlayURI:))
            )
        )
    }

    /// Artist for a track. For a favorite, the service it came from - which is what
    /// `r:description` holds, and the most useful thing to show when a list mixes services.
    private var subtitle: String? {
        [text["dc:creator"], text["r:description"], text["upnp:album"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}
