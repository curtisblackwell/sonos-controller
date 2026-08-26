import AppKit
import SwiftUI

/// Hosts the grouping editor in a real window.
///
/// Also gates the volume polling: the sliders are the only thing that reads volume, so
/// there is no reason to be asking the household for numbers nobody can see.
final class GroupingWindowController: NSWindowController {
    private let model: TopologyModel
    private let volume: VolumeModel
    private let playback: PlaybackModel
    private var observers: [NSObjectProtocol] = []

    init(model: TopologyModel, volume: VolumeModel, playback: PlaybackModel) {
        self.model = model
        self.volume = volume
        self.playback = playback
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Speaker Groups"
        window.contentView = NSHostingView(rootView: GroupingView(model: model, volume: volume, playback: playback))
        // Centre before adopting the autosaved frame: contentRect's origin is (0,0), so a
        // first launch with nothing saved would otherwise put the app's main window in the
        // bottom-left corner, behind the Dock.
        window.center()
        window.setFrameAutosaveName("GroupingWindow")
        window.isReleasedWhenClosed = false
        super.init(window: window)

        // Occlusion covers every way the sliders stop being readable in one signal:
        // minimised, hidden behind another app, on another Space, or the app hidden
        // outright. Closing is the one it reports too late to be the only thing we watch.
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.syncPolling()
        })
        observers.append(center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.volume.stopPolling()
            self?.playback.stopPolling()
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        model.refresh()
        syncPolling()
    }

    private func syncPolling() {
        guard let window else { return }
        if window.isVisible, window.occlusionState.contains(.visible) {
            volume.startPolling()
            playback.startPolling()
        } else {
            volume.stopPolling()
            playback.stopPolling()
        }
    }
}
