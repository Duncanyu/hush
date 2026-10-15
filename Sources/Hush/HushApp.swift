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
        editMenu.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)),
                           keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        app.windowsMenu = windowMenu
        app.mainMenu = mainMenu
        app.delegate = delegate
        app.run()
    }
}

private final class HushDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate,
                                  NSMenuItemValidation {
    private let model = HushModel()
    private let updater = HushUpdater()
    private let undoManager = UndoManager()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?
    private var iconObserver: Any?
    private var visualizerTimer: Timer?
    private var visualizerLevels = Array(repeating: 0.0, count: 8)
    private var lastRenderedBands: [Double]?
    private var lastRenderedEnabled = false
    private var lastRenderedVisualizer = false
    private var hasRenderedIcon = false
    private let bundledIconSVG = """
    <svg viewBox="0 0 128 128" xmlns="http://www.w3.org/2000/svg"><g fill="none" stroke="currentColor" stroke-width="10.5" stroke-linecap="round" stroke-linejoin="round"><rect x="15" y="15" width="98" height="98" rx="28"/><path d="M30 70 C40 70 40 48 50 48 S60 83 72 83 S85 58 98 58"/></g></svg>
    """

    func applicationDidFinishLaunching(_ notification: Notification) {
        iconObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateStatusIcon() }
        updateVisibility()
        model.start()
        updater.start(enabled: model.settings.automaticUpdates)
        configureVisualizerTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let iconObserver { NotificationCenter.default.removeObserver(iconObserver) }
        visualizerTimer?.invalidate()
        updater.stop()
        model.shutdown()
    }

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
                item.button?.action = #selector(togglePanel)
                item.button?.target = self
                statusItem = item
            }
            updateStatusIcon()
        } else {
            popover?.close()
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem); self.statusItem = nil }
            NSApp.setActivationPolicy(.regular)
            showSettings()
        }
    }

    private func updateStatusIcon() {
        configureVisualizerTimer()
        guard let button = statusItem?.button else { return }
        let visualizer = model.settings.masterEnabled && model.settings.visualizerEnabled
        let bands = model.diagnostics.value.bandLevels
        if hasRenderedIcon && visualizer == lastRenderedVisualizer &&
            model.settings.masterEnabled == lastRenderedEnabled &&
            (!visualizer || bands == lastRenderedBands) {
            return
        }
        hasRenderedIcon = true
        lastRenderedEnabled = model.settings.masterEnabled
        lastRenderedVisualizer = visualizer
        lastRenderedBands = bands
        if visualizer {
            button.image = visualizerImage(bands: bands)
            button.image?.isTemplate = true
        } else if let image = NSImage(data: Data(bundledIconSVG.utf8)) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            button.image = image
        } else {
            button.image = NSImage(systemSymbolName: "waveform.slash", accessibilityDescription: "Hush disabled")
        }
        button.toolTip = model.settings.masterEnabled ? "Hush enabled" : "Hush disabled"
    }

    private func configureVisualizerTimer() {
        let shouldRun = model.settings.masterEnabled && model.settings.visualizerEnabled &&
            statusItem != nil
        if shouldRun, visualizerTimer == nil {
            visualizerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) {
                [weak self] _ in
                self?.model.refreshDiagnostics()
                self?.updateStatusIcon()
            }
        } else if !shouldRun {
            visualizerTimer?.invalidate()
            visualizerTimer = nil
        }
    }

    private func visualizerImage(bands: [Double]) -> NSImage {
        for index in visualizerLevels.indices {
            let target = min(1, max(0, index < bands.count ? bands[index] * 3.5 : 0))
            let desired = target
            let response = desired > visualizerLevels[index] ? 0.65 : 0.22
            visualizerLevels[index] += (desired - visualizerLevels[index]) * response
        }
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        NSColor.white.setStroke()
        NSColor.white.setFill()
        let barWidth = 1.25
        let gap = 0.7
        for (index, value) in visualizerLevels.enumerated() {
            let height = max(1.4, CGFloat(value) * 15)
            let x = 1.0 + CGFloat(index) * (barWidth + gap)
            let rect = NSRect(x: x, y: (18 - height) / 2, width: barWidth, height: height)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    @objc private func togglePanel() {
        guard let button = statusItem?.button else { return }
        if popover?.isShown == true { popover?.close(); return }
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSPopover()
        panel.behavior = .transient
        panel.contentSize = NSSize(width: 400, height: 520)
        panel.contentViewController = NSHostingController(rootView: QuickPanel(model: model,
            openSettings: { [weak self] in self?.popover?.close(); self?.showSettings() },
            quit: { NSApp.terminate(nil) }))
        panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover = panel
        panel.contentViewController?.view.window?.makeKey()
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
                                                                      undoManager: undoManager,
                                                                      updatePreferenceChanged: { [weak self] enabled in
                                                                          self?.updater.setEnabled(enabled)
                                                                      }))
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
