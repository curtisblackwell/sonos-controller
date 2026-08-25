import AppKit
import SwiftUI
import os.log

/// Hosts the grouping editor in a real window.
///
/// The app is an `LSUIElement` agent, so it has no Dock icon and no menu bar of its own.
/// While the editor is open we switch to `.regular` so the window behaves like a normal
/// one - Dock icon, Cmd-Tab, and the standard menu bar with working Cmd-W/Cmd-Q/Cmd-C/Cmd-V,
/// all of which we would otherwise have to hand-build - then drop back to `.accessory`
/// when it closes.
final class GroupingWindowController: NSWindowController, NSWindowDelegate {
    private static let log = Logger(subsystem: "com.curtis.sonos-controller", category: "window")

    private let model: TopologyModel

    init(model: TopologyModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Speaker Groups"
        window.contentView = NSHostingView(rootView: GroupingView(model: model))
        window.setFrameAutosaveName("GroupingWindow")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        NSApp.setActivationPolicy(.regular)
        // Switching agent -> regular leaves the app not-quite-frontmost: the menu bar can
        // come up disabled until something else activates it, and activate() alone in the
        // same turn of the run loop doesn't reliably fix it. Ordering the window front
        // first and activating on the next turn does.
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            self.window?.makeKeyAndOrderFront(nil)
        }
        model.refresh()
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a Dock-less agent. Deferred so the window is actually gone first -
        // switching policy while it's still closing leaves a stray Dock icon behind.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
