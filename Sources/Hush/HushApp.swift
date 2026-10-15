import AppKit
import SwiftUI

@main
struct HushApp {
    private static let delegate = HushDelegate()

    static func main() {
        let app = NSApplication.shared
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Hush", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        let undo = editMenu.addItem(withTitle: "Undo", action: #selector(HushDelegate.undo(_:)), keyEquivalent: "z")
        undo.target = delegate
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        app.mainMenu = mainMenu
        app.delegate = delegate
        app.run()
    }
}

private final class HushDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate,
                                  NSMenuItemValidation {
    private let model = HushModel()
    private let undoManager = UndoManager()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateVisibility()
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }

    func applicationDidResignActive(_ notification: Notification) { popover?.close() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undoManager }

    @objc func undo(_ sender: Any?) { undoManager.undo() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(undo(_:)) {
            item.title = undoManager.undoMenuItemTitle
            return undoManager.canUndo
        }
        return true
    }

    private func updateVisibility() {
        if model.settings.showMenuBar {
            NSApp.setActivationPolicy(.accessory)
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Hush")
                item.button?.action = #selector(togglePanel)
                item.button?.target = self
                statusItem = item
            }
        } else {
            popover?.close()
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem); self.statusItem = nil }
            NSApp.setActivationPolicy(.regular)
            showSettings()
        }
    }

    @objc private func togglePanel() {
        guard let button = statusItem?.button else { return }
        if popover?.isShown == true { popover?.close(); return }
        model.refresh()
        let panel = NSPopover()
        panel.behavior = .transient
        panel.contentSize = NSSize(width: 400, height: 510)
        panel.contentViewController = NSHostingController(rootView: QuickPanel(model: model,
            openSettings: { [weak self] in self?.popover?.close(); self?.showSettings() },
            quit: { NSApp.terminate(nil) }))
        panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover = panel
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 660),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Hush"
            window.appearance = NSAppearance(named: .aqua)
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(rootView: SettingsView(model: model,
                                                                      visibilityChanged: { [weak self] in self?.updateVisibility() },
                                                                      undoManager: undoManager))
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
