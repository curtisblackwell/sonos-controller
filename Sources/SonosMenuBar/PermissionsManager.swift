import Foundation
import ApplicationServices
import AppKit

enum PermissionsManager {
    static func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the one-time system prompt if not yet decided. No-op if already denied.
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// There is no API to query or re-prompt for Local Network access - the system asks
    /// once, and a denial silently blackholes SSDP forever. All we can do is point the
    /// user at the toggle when discovery turns up nothing.
    static func openLocalNetworkSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") else { return }
        NSWorkspace.shared.open(url)
    }
}
