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
}
