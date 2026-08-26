import AppKit
import CoreGraphics
import os.log

private let NX_KEYTYPE_PLAY: Int32 = 16
private let NX_KEYTYPE_NEXT: Int32 = 17
private let NX_KEYTYPE_PREVIOUS: Int32 = 18
// Some keyboards send the "fast-forward/rewind" codes for the F7/F9 media
// keys instead of NEXT/PREVIOUS - treat them the same way.
private let NX_KEYTYPE_FAST: Int32 = 19
private let NX_KEYTYPE_REWIND: Int32 = 20
private let NX_KEYSTATE_DOWN: Int32 = 0x0A
private let mediaKeySubtype: Int16 = 8
private let systemDefinedEventType: UInt32 = 14

/// Watches for the F7/F8/F9 media keys and swallows them so Apple Music doesn't also react.
///
/// The tap is an *active* `.cgSessionEventTap`: the window server hands each matching event
/// to this process and holds the session's input stream until the callback answers. That
/// makes the callback part of every user's input path, so it runs on a dedicated thread and
/// does nothing but decode the key - the handlers are dispatched to main afterwards. Running
/// it on the main run loop (as this used to) meant any main-thread stall - a slow
/// `AXIsProcessTrusted()`, a SwiftUI layout pass - froze mouse clicks and keystrokes
/// system-wide until the window server gave up on the tap.
final class MediaKeyTap {
    private static let log = Logger(subsystem: "com.curtisblackwell.sonos-controller", category: "mediakeys")

    /// How long the tap thread parks before checking that its tap is still alive.
    private static let revalidateInterval: CFTimeInterval = 10

    /// Assigned before `install()` and not changed afterwards, so the tap thread can read
    /// them without synchronisation.
    var onPlayPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?

    /// Called on the main thread when the tap comes up or goes down, so the app can stop
    /// and restart its permission polling.
    var onInstallStateChanged: ((Bool) -> Void)?

    /// Called on the main thread once the tap has failed to come up enough times that the
    /// grant is clearly not going to take effect in this process. Fires once per run of
    /// failures, so it is safe to show something to the user from it.
    var onNeedsRelaunch: (() -> Void)?

    /// Owned by the tap thread once it is running.
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?

    /// Everything the main thread touches goes through this lock.
    private let lock = NSLock()
    private var started = false
    /// Consecutive times the tap came up empty. `AXIsProcessTrusted()` can report the grant
    /// while `tapCreate` still refuses - a grant made while the app was already running
    /// usually needs a relaunch - and the permission poll would otherwise spin up and tear
    /// down a thread every two seconds forever.
    private var failedAttempts = 0
    /// Uptime (not wall clock, which a clock change could move backwards) before which
    /// `install()` declines to try again.
    private var retryNotBefore: TimeInterval = 0

    /// Failures before we stop treating it as "not granted yet" and tell the user.
    private static let failuresBeforeGivingUp = 3
    /// 2s, 4s, 8s… capped. The permission poll runs every 2s, so without this every tick
    /// spawns a thread.
    private static let maxRetryBackoff: TimeInterval = 30

    var isInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    /// Brings the tap up on its own thread. Idempotent and non-blocking - the caller never
    /// waits on `CGEvent.tapCreate`, and the result arrives via `onInstallStateChanged`.
    func install() {
        lock.lock()
        guard !started, ProcessInfo.processInfo.systemUptime >= retryNotBefore else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        let thread = Thread { [weak self] in self?.runTapThread() }
        thread.name = "com.curtisblackwell.sonos-controller.mediakeys"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    // MARK: - Tap thread

    private func runTapThread() {
        tapRunLoop = CFRunLoopGetCurrent()

        guard createTap() else {
            Self.log.notice("CGEvent.tapCreate failed - Accessibility permission likely not granted yet")
            finishTapThread(didInstall: false)
            return
        }
        Self.log.notice("Media key tap installed")
        lock.lock()
        failedAttempts = 0
        retryNotBefore = 0
        lock.unlock()
        notifyInstallState(true)

        // Parks this thread servicing the tap and nothing else. The timeout is just a
        // heartbeat for `revalidate()`; it isn't a poll of anything expensive.
        //
        // The pool is this thread's own - `NSEvent(cgEvent:)` autoreleases once per
        // system-defined event machine-wide, and on the main run loop AppKit drained those
        // for us. Nothing drains a bare `CFRunLoopRunInMode`, so without this they pile up
        // for as long as the app runs.
        while !Thread.current.isCancelled {
            let stop = autoreleasepool { () -> Bool in
                let result = CFRunLoopRunInMode(.defaultMode, Self.revalidateInterval, false)
                if result == .stopped || result == .finished { return true }
                // A rebuild that failed leaves no tap to service, so end the thread and let
                // `onInstallStateChanged(false)` restart the permission polling that will
                // call `install()` again. Relying on the run loop to report `.finished`
                // because the mode went empty would silently stop working the moment
                // anything else is scheduled on this thread.
                return !revalidate()
            }
            if stop { break }
        }

        finishTapThread(didInstall: true)
    }

    /// Must be called on the tap thread.
    private func createTap() -> Bool {
        let eventMask: CGEventMask = 1 << systemDefinedEventType
        let callback: CGEventTapCallBack = { _, type, cgEvent, refcon in
            guard let refcon else { return Unmanaged.passUnretained(cgEvent) }
            let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.handle(type: type, cgEvent: cgEvent)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// macOS disables a tap that answered too slowly and invalidates it outright when
    /// Accessibility is revoked - and revives neither on its own. Returns false when there
    /// is no longer a live tap to service. Must be called on the tap thread.
    @discardableResult
    private func revalidate() -> Bool {
        guard let tap = eventTap else { return false }
        if CFMachPortIsValid(tap) {
            if !CGEvent.tapIsEnabled(tap: tap) {
                Self.log.notice("Media key tap was disabled, re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return true
        }
        Self.log.notice("Media key tap is dead, rebuilding")
        teardown()
        if createTap() { return true }
        Self.log.notice("Rebuild failed - Accessibility permission is probably gone")
        return false
    }

    /// Must be called on the tap thread. `didInstall` separates "the tap ran and then went
    /// away" from "it never came up at all" - only the latter backs off, since a tap that
    /// worked once should be retried immediately.
    private func finishTapThread(didInstall: Bool) {
        teardown()

        lock.lock()
        started = false
        var giveUp = false
        if didInstall {
            failedAttempts = 0
            retryNotBefore = 0
        } else {
            failedAttempts += 1
            let backoff = min(Self.maxRetryBackoff, pow(2, Double(failedAttempts)))
            retryNotBefore = ProcessInfo.processInfo.systemUptime + backoff
            giveUp = failedAttempts == Self.failuresBeforeGivingUp
        }
        let attempts = failedAttempts
        lock.unlock()

        if giveUp {
            Self.log.error("Media key tap failed \(attempts, privacy: .public) times with Accessibility reported as granted - the app probably needs a relaunch")
            DispatchQueue.main.async { [weak self] in self?.onNeedsRelaunch?() }
        }
        notifyInstallState(false)
    }

    /// Must be called on the tap thread.
    private func teardown() {
        if let source = runLoopSource, let runLoop = tapRunLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        runLoopSource = nil
        if let tap = eventTap {
            if CFMachPortIsValid(tap) {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
        }
        eventTap = nil
    }

    private func notifyInstallState(_ installed: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.onInstallStateChanged?(installed)
        }
    }

    // MARK: - Event handling

    /// Runs inside the system's input path - see the note on the type. Everything here is
    /// decode-only; no I/O, no locks, no AppKit work beyond reading the event.
    private func handle(type: CGEventType, cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(cgEvent)
        }

        // The event is owned by the caller, so it goes back unretained - returning it
        // retained leaks a CGEvent for every system-defined event on the machine.
        guard type.rawValue == systemDefinedEventType else {
            return Unmanaged.passUnretained(cgEvent)
        }

        // `NSEvent(cgEvent:)` autoreleases, and this runs for every system-defined event on
        // the machine, so it gets its own pool rather than waiting for the run loop to come
        // back around. `cgEvent` is the caller's and is untouched by the drain.
        let pressed: (handler: (() -> Void)?, isKeyDown: Bool, keyCode: Int32)? = autoreleasepool {
            guard let nsEvent = NSEvent(cgEvent: cgEvent),
                  nsEvent.subtype.rawValue == mediaKeySubtype else { return nil }

            let data1 = UInt32(truncatingIfNeeded: nsEvent.data1)
            let keyCode = Int32((data1 & 0xFFFF0000) >> 16)
            let isKeyDown = Int32((data1 & 0xFF00) >> 8) == NX_KEYSTATE_DOWN

            switch keyCode {
            case NX_KEYTYPE_PLAY:
                return (onPlayPause, isKeyDown, keyCode)
            case NX_KEYTYPE_NEXT, NX_KEYTYPE_FAST:
                return (onNext, isKeyDown, keyCode)
            case NX_KEYTYPE_PREVIOUS, NX_KEYTYPE_REWIND:
                return (onPrevious, isKeyDown, keyCode)
            default:
                return nil
            }
        }

        guard let pressed else { return Unmanaged.passUnretained(cgEvent) }

        // Both the down and the up are swallowed, so nothing else on the system sees the
        // key - but only the down does anything.
        if pressed.isKeyDown, let handler = pressed.handler {
            let keyCode = pressed.keyCode
            DispatchQueue.main.async {
                Self.log.notice("media key: code=\(keyCode, privacy: .public)")
                handler()
            }
        }
        return nil
    }
}
