import AppKit
import SwiftUI

/// Hosts the grouping editor in a real window.
final class GroupingWindowController: NSWindowController {
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
        // Centre before adopting the autosaved frame: contentRect's origin is (0,0), so a
        // first launch with nothing saved would otherwise put the app's main window in the
        // bottom-left corner, behind the Dock.
        window.center()
        window.setFrameAutosaveName("GroupingWindow")
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        model.refresh()
    }
}
