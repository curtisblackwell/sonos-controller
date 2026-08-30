import AppKit
import SwiftUI

/// Hosts the app's main window.
///
/// Also gates the volume and playback polling: the sliders and the now-playing bar are the
/// only things that read them, so there is no reason to be asking the household for numbers
/// nobody can see.
final class MainWindowController: NSWindowController {
    private let model: TopologyModel
    private let volume: VolumeModel
    private let playback: PlaybackModel
    private let browse: BrowseModel
    private let spotifySearch: SpotifySearchModel
    private let spotifyAuth: SpotifyAuth
    private var observers: [NSObjectProtocol] = []

    init(
        model: TopologyModel,
        volume: VolumeModel,
        playback: PlaybackModel,
        browse: BrowseModel,
        spotifySearch: SpotifySearchModel,
        spotifyAuth: SpotifyAuth
    ) {
        self.model = model
        self.volume = volume
        self.playback = playback
        self.browse = browse
        self.spotifySearch = spotifySearch
        self.spotifyAuth = spotifyAuth
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sonos"
        window.contentView = NSHostingView(
            rootView: MainWindowView(
                model: model,
                volume: volume,
                playback: playback,
                browse: browse,
                spotifySearch: spotifySearch,
                spotifyAuth: spotifyAuth
            )
        )
        // Centre before adopting the autosaved frame: contentRect's origin is (0,0), so a
        // first launch with nothing saved would otherwise put the app's main window in the
        // bottom-left corner, behind the Dock.
        window.center()
        // Still the pre-sidebar name on purpose: this is a UserDefaults key, and renaming it
        // would throw away the window position and size every existing user has set.
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
