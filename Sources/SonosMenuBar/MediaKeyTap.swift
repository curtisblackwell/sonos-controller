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

final class MediaKeyTap {
    private static let log = Logger(subsystem: "com.curtis.sonos-controller", category: "mediakeys")

    var onPlayPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Returns true if a live tap is in place. Safe to call repeatedly - if an existing
    /// tap has gone dead (macOS invalidates it when Accessibility is revoked, and does not
    /// revive it when the permission comes back) it is torn down and rebuilt rather than
    /// reported as still working.
    @discardableResult
    func install() -> Bool {
        if let tap = eventTap {
            if CFMachPortIsValid(tap) {
                if CGEvent.tapIsEnabled(tap: tap) { return true }
                CGEvent.tapEnable(tap: tap, enable: true)
                if CGEvent.tapIsEnabled(tap: tap) { return true }
            }
            Self.log.notice("Existing media key tap is dead, rebuilding")
            teardown()
        }

        let eventMask: CGEventMask = 1 << systemDefinedEventType
        let callback: CGEventTapCallBack = { proxy, type, cgEvent, refcon in
            guard let refcon else { return Unmanaged.passRetained(cgEvent) }
            let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.handle(proxy: proxy, type: type, cgEvent: cgEvent)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: refcon
        ) else {
            Self.log.notice("CGEvent.tapCreate failed - Accessibility permission likely not granted yet")
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        if let source {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        Self.log.notice("Media key tap installed")
        return true
    }

    private func teardown() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        runLoopSource = nil
        if let tap = eventTap, CFMachPortIsValid(tap) {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passRetained(cgEvent)
        }

        guard type.rawValue == systemDefinedEventType else {
            return Unmanaged.passRetained(cgEvent)
        }
        guard let nsEvent = NSEvent(cgEvent: cgEvent) else {
            Self.log.notice("systemDefined CGEvent but NSEvent(cgEvent:) returned nil")
            return Unmanaged.passRetained(cgEvent)
        }
        Self.log.notice("systemDefined event received, subtype=\(nsEvent.subtype.rawValue, privacy: .public) data1=\(nsEvent.data1, privacy: .public)")
        guard nsEvent.subtype.rawValue == mediaKeySubtype else {
            return Unmanaged.passRetained(cgEvent)
        }

        let data1 = UInt32(truncatingIfNeeded: nsEvent.data1)
        let keyCode = Int32((data1 & 0xFFFF0000) >> 16)
        let keyState = Int32((data1 & 0xFF00) >> 8)
        let isKeyDown = keyState == NX_KEYSTATE_DOWN
        Self.log.notice("media key: code=\(keyCode, privacy: .public) down=\(isKeyDown, privacy: .public)")

        switch keyCode {
        case NX_KEYTYPE_PLAY:
            if isKeyDown { onPlayPause?() }
            return nil
        case NX_KEYTYPE_NEXT, NX_KEYTYPE_FAST:
            if isKeyDown { onNext?() }
            return nil
        case NX_KEYTYPE_PREVIOUS, NX_KEYTYPE_REWIND:
            if isKeyDown { onPrevious?() }
            return nil
        default:
            return Unmanaged.passRetained(cgEvent)
        }
    }
}
