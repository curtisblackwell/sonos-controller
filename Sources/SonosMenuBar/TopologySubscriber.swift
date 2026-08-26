import AppKit
import Foundation
import os.log

/// Keeps a live GENA subscription to ZoneGroupTopology so that regrouping done anywhere else
/// - the Sonos app, another controller, a speaker's own buttons - shows up here without
/// polling for it.
///
/// Any single ZonePlayer reports the whole household, so one subscription is enough. The
/// candidate list exists only to fail over when the player we picked goes away.
///
/// Main thread only. Every callback it takes - from the listener, from GENA, from its timers
/// - already lands there, so the state below needs no further synchronisation.
final class TopologySubscriber {
    private static let log = Logger(subsystem: "com.curtis.sonos-controller", category: "topology-subscriber")

    /// Events arrive in a burst while the household settles - moving one room fires several
    /// - and each carries the full topology, so only the last one is worth acting on.
    private static let coalesceDelay: TimeInterval = 0.4
    /// Used when every candidate refused a subscription. Discovery re-arms us too; this is
    /// for the case where nothing else happens to run.
    private static let retryDelay: TimeInterval = 30

    /// Called on the main thread with a fresh topology.
    var onTopology: (([SonosGroup]) -> Void)?

    private let listener = GENAEventListener()
    private var candidateIPs: [String] = []
    private var subscribedIP: String?
    /// The speaker a SUBSCRIBE is in flight to. Its first event routinely beats the response
    /// back, so events have to be attributable to it before there is a SID to match.
    private var pendingIP: String?
    private var sid: String?
    private var isSubscribing = false
    /// Set when the candidate list changes mid-SUBSCRIBE. Acting on it there would leave the
    /// in-flight response to bind a speaker we've already decided against.
    private var needsRestart = false
    private var renewTimer: Timer?
    private var retryTimer: Timer?
    private var coalesceTimer: Timer?
    private var pendingGroups: [SonosGroup]?
    private var wakeObserver: NSObjectProtocol?

    func start() {
        listener.onEvent = { [weak self] sid, sourceIP, body in
            self?.handleEvent(sid: sid, sourceIP: sourceIP, body: body)
        }
        listener.start { [weak self] port in
            guard let self else { return }
            guard port != nil else {
                Self.log.error("No event listener, live topology updates are off")
                return
            }
            self.subscribeToFirstReachable()
        }
        // A subscription doesn't survive sleep: the lease expires while we're down, and the
        // address in the callback URL may not even be ours any more when we come back.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Not a renewal: the callback URL names an address that may have changed while
            // we were asleep, and only a fresh SUBSCRIBE re-states it.
            self.dropSubscription()
            self.subscribeToFirstReachable()
        }
    }

    /// Fed from discovery. Re-subscribes only when the speaker we're subscribed to has
    /// dropped out of the household - an unchanged list is the common case and must not
    /// churn a working subscription.
    func update(candidateIPs: [String]) {
        // A scan that found nothing is far more often a missed multicast than a household
        // that has gone away. Tearing down a working subscription over it loses live updates
        // until someone thinks to hit Rescan.
        guard !candidateIPs.isEmpty else { return }
        self.candidateIPs = candidateIPs

        // Let the in-flight attempt land first; it re-checks the list against what it bound.
        guard !isSubscribing else {
            needsRestart = true
            return
        }
        if sid != nil, let subscribedIP, candidateIPs.contains(subscribedIP) { return }
        dropSubscription()
        subscribeToFirstReachable()
    }

    func stop() {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        coalesceTimer?.invalidate()
        coalesceTimer = nil
        dropSubscription()
        listener.stop()
    }

    // MARK: - Subscription lifecycle

    private func subscribeToFirstReachable() {
        needsRestart = false
        // Walk a snapshot: discovery can replace `candidateIPs` while an attempt is in the
        // air, and an index into the old list picks an unrelated speaker out of the new one.
        subscribe(to: candidateIPs, index: 0)
    }

    /// Walks the candidates in order until one accepts. A speaker that answered SSDP can
    /// still refuse or time out here, so a single failure isn't a reason to give up.
    private func subscribe(to candidates: [String], index: Int) {
        guard sid == nil, !isSubscribing, listener.port != nil else { return }
        retryTimer?.invalidate()
        retryTimer = nil

        guard index < candidates.count else {
            guard !candidates.isEmpty else { return }
            Self.log.notice("No speaker accepted a topology subscription, retrying in \(Int(Self.retryDelay), privacy: .public)s")
            retryTimer = Timer.scheduledTimer(withTimeInterval: Self.retryDelay, repeats: false) { [weak self] _ in
                self?.subscribeToFirstReachable()
            }
            return
        }

        let ip = candidates[index]
        guard let eventURL = Self.eventURL(ip: ip), let callbackURL = listener.callbackURL(reachableFrom: ip) else {
            subscribe(to: candidates, index: index + 1)
            return
        }

        isSubscribing = true
        pendingIP = ip
        GENA.subscribe(eventURL: eventURL, callbackURL: callbackURL) { [weak self] result in
            guard let self else { return }
            self.isSubscribing = false
            self.pendingIP = nil
            switch result {
            case let .success(lease):
                Self.log.notice("Subscribed to \(ip, privacy: .public) topology, lease \(Int(lease.timeout), privacy: .public)s")
                self.sid = lease.sid
                self.subscribedIP = ip
                self.scheduleRenew(after: lease.timeout)
                // The list may have been replaced while this was in the air. Only start over
                // if the speaker we just bound has gone from it - a list that still contains
                // it is a subscription worth keeping, and tearing it down here churned one
                // per scan at launch.
                self.needsRestart = false
                if !self.candidateIPs.contains(ip) {
                    self.dropSubscription()
                    self.subscribeToFirstReachable()
                }
            case let .failure(error):
                Self.log.notice("SUBSCRIBE to \(ip, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                guard !self.needsRestart else {
                    self.subscribeToFirstReachable()
                    return
                }
                self.subscribe(to: candidates, index: index + 1)
            }
        }
    }

    /// Renew at half the lease so a single lost renewal still has a second chance before
    /// the speaker forgets us.
    private func scheduleRenew(after timeout: TimeInterval) {
        renewTimer?.invalidate()
        renewTimer = Timer.scheduledTimer(withTimeInterval: max(30, timeout / 2), repeats: false) { [weak self] _ in
            self?.renew()
        }
    }

    private func renew() {
        guard let sid, let ip = subscribedIP, let eventURL = Self.eventURL(ip: ip) else { return }
        GENA.renew(eventURL: eventURL, sid: sid) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(lease):
                self.sid = lease.sid
                self.scheduleRenew(after: lease.timeout)
            case let .failure(error):
                // The speaker rebooted, or the lease lapsed. The SID is worthless either
                // way, so start over rather than keep renewing against it.
                Self.log.notice("Renewal for \(ip, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                self.renewTimer?.invalidate()
                self.renewTimer = nil
                self.sid = nil
                self.subscribedIP = nil
                self.subscribeToFirstReachable()
            }
        }
    }

    private func dropSubscription() {
        renewTimer?.invalidate()
        renewTimer = nil
        retryTimer?.invalidate()
        retryTimer = nil
        if let sid, let ip = subscribedIP, let eventURL = Self.eventURL(ip: ip) {
            GENA.unsubscribe(eventURL: eventURL, sid: sid)
        }
        sid = nil
        subscribedIP = nil
        pendingIP = nil
    }

    // MARK: - Events

    /// A topology decides where the media keys point, so an event has to come from the
    /// speaker we subscribed to. Matching on SID alone isn't enough on its own: the first
    /// NOTIFY routinely beats the SUBSCRIBE response back, so there is a window with no SID
    /// to match - which is what `pendingIP` covers. Once we have a SID, it must agree too.
    private func handleEvent(sid: String, sourceIP: String, body: Data) {
        let expectedIP = subscribedIP ?? pendingIP
        guard let expectedIP, sourceIP == expectedIP else {
            Self.log.notice("Ignoring a topology event from \(sourceIP, privacy: .public)")
            return
        }
        if let ourSID = self.sid, sid != ourSID {
            Self.log.notice("Ignoring a topology event with an unknown SID")
            return
        }

        let groups = SonosTopology.parseGroups(fromEventBody: body)
        Self.log.notice("Topology event carrying \(groups.count, privacy: .public) groups")
        // An event we can't parse, or one for a household with nothing controllable in it,
        // must not be allowed to blank out a topology we already have.
        guard !groups.isEmpty else { return }

        pendingGroups = groups
        guard coalesceTimer == nil else { return }
        coalesceTimer = Timer.scheduledTimer(withTimeInterval: Self.coalesceDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.coalesceTimer = nil
            guard let groups = self.pendingGroups else { return }
            self.pendingGroups = nil
            self.onTopology?(groups)
        }
    }

    private static func eventURL(ip: String) -> URL? {
        URL(string: "http://\(ip):1400/ZoneGroupTopology/Event")
    }
}
