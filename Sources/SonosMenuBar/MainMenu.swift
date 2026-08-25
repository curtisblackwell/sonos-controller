import AppKit

/// Builds the app's main menu bar.
///
/// As an `.accessory` app there was no menu bar to fill in, and the standard editing key
/// equivalents came for free from whatever app was frontmost. As a `.regular` app the menu
/// bar is ours, and an app without one gets a nearly empty bar that looks broken.
///
/// This is also what makes text input work: Cmd-C / Cmd-V / Cmd-A / Cmd-Z in a text field
/// are key equivalents on the Edit menu, not built into `NSTextField`. Without an Edit menu
/// a search field silently ignores all of them.
enum MainMenu {
    static func build(appName: String) -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(submenu: appMenu(appName: appName))
        mainMenu.addItem(submenu: editMenu())
        let window = windowMenu()
        mainMenu.addItem(submenu: window)
        NSApp.windowsMenu = window
        return mainMenu
    }

    private static func appMenu(appName: String) -> NSMenu {
        let menu = NSMenu(title: appName)
        menu.addItem(title: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        menu.addItem(.separator())
        menu.addItem(title: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        menu.addItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(title: "Delete", action: #selector(NSText.delete(_:)))
        menu.addItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        menu.addItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)))
        return menu
    }
}

private extension NSMenu {
    /// Menu bar submenus need a carrier item whose title AppKit reads for the bar itself.
    func addItem(submenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }

    @discardableResult
    func addItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        // No target: these travel the responder chain, which is what lets Cut/Copy/Paste
        // reach whichever text field is focused.
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        addItem(item)
        return item
    }
}
