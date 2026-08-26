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

    /// Owned by the tap thread once it is running.
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?

    /// `started` is the one piece of state the main thread touches, so it takes the lock.
    private let lock = NSLock()
    private var started = false

    var isInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    /// Brings the tap up on its own thread. Idempotent and non-blocking - the caller never
    /// waits on `CGEvent.tapCreate`, and the result arrives via `onInstallStateChanged`.
    func install() {
        lock.lock()
        if started {
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
            finishTapThread()
            return
        }
        Self.log.notice("Media key tap installed")
        notifyInstallState(true)

        // Parks this thread servicing the tap and nothing else. The timeout is just a
        // heartbeat for `revalidate()`; it isn't a poll of anything expensive.
        while !Thread.current.isCancelled {
            let result = CFRunLoopRunInMode(.defaultMode, Self.revalidateInterval, false)
            if result == .stopped || result == .finished { break }
            revalidate()
        }

        finishTapThread()
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
    /// Accessibility is revoked - and revives neither on its own. Must be called on the
    /// tap thread.
    private func revalidate() {
        guard let tap = eventTap else { return }
        if CFMachPortIsValid(tap) {
            if !CGEvent.tapIsEnabled(tap: tap) {
                Self.log.notice("Media key tap was disabled, re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        Self.log.notice("Media key tap is dead, rebuilding")
        teardown()
        if !createTap() {
            Self.log.notice("Rebuild failed - Accessibility permission is probably gone")
        }
    }

    /// Must be called on the tap thread.
    private func finishTapThread() {
        teardown()
        lock.lock()
        started = false
        lock.unlock()
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
        guard type.rawValue == systemDefinedEventType,
              let nsEvent = NSEvent(cgEvent: cgEvent),
              nsEvent.subtype.rawValue == mediaKeySubtype else {
            return Unmanaged.passUnretained(cgEvent)
        }

        let data1 = UInt32(truncatingIfNeeded: nsEvent.data1)
        let keyCode = Int32((data1 & 0xFFFF0000) >> 16)
        let isKeyDown = Int32((data1 & 0xFF00) >> 8) == NX_KEYSTATE_DOWN

        let handler: (() -> Void)?
        switch keyCode {
        case NX_KEYTYPE_PLAY:
            handler = onPlayPause
        case NX_KEYTYPE_NEXT, NX_KEYTYPE_FAST:
            handler = onNext
        case NX_KEYTYPE_PREVIOUS, NX_KEYTYPE_REWIND:
            handler = onPrevious
        default:
            return Unmanaged.passUnretained(cgEvent)
        }

        // Both the down and the up are swallowed, so nothing else on the system sees the
        // key - but only the down does anything.
        if isKeyDown, let handler {
            DispatchQueue.main.async {
                Self.log.notice("media key: code=\(keyCode, privacy: .public)")
                handler()
            }
        }
        return nil
    }
}
