import AppKit
import QuartzCore
import SwiftUI

final class LyricsFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var appState: AppState!
    private var eventMonitor: Any?
    private var notchController: NotchCapsuleController?
    private var notchOverlayController: NotchOverlayController?
    private var openPanelObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        appState = AppState()
        configureStatusItem()
        configurePanel()
        observeMenuTitle()
        notchController = NotchCapsuleController(appState: appState)
        notchOverlayController = NotchOverlayController(appState: appState)
        openPanelObserver = NotificationCenter.default.addObserver(
            forName: .openLyricsPanel, object: nil, queue: .main
        ) { [weak self] notification in
            let anchorRect = (notification.userInfo?[LyricsPanelAnchorNotificationKey.anchorFrame] as? NSValue)?.rectValue
            let screenNumber = (notification.userInfo?[LyricsPanelAnchorNotificationKey.screenNumber] as? NSNumber)?.intValue
            Task { @MainActor in
                guard let self else { return }
                if let anchorRect,
                   let screenNumber,
                   let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue == screenNumber }) {
                    self.showPanel(anchorFrame: anchorRect, on: screen, preferredEdge: .below)
                } else if let button = self.statusItem.button {
                    self.showPanel(relativeTo: button)
                }
            }
        }
        appState.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        appState.stop()
    }

    /// Menu-bar-only apps must not quit just because the last visible window
    /// (e.g. the desktop bar) closed. Quit lives in the right-click status menu.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "SpotLyrics"
        statusItem.button?.font = .systemFont(ofSize: NSFont.systemFontSize)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePanel() {
        panel = LyricsFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 520),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentViewController = NSHostingController(
            rootView: PanelRootView().environmentObject(appState)
        )
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
    }

    private func observeMenuTitle() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for await title in self.appState.$menuTitle.values {
                self.statusItem.button?.title = title
            }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu(from: button)
            return
        }
        if panel.isVisible {
            closePanel()
        } else {
            showPanel(relativeTo: button)
        }
    }

    private func showPanel(relativeTo button: NSStatusBarButton) {
        appState.refreshNow(forceLyrics: false)

        let buttonFrame: NSRect
        let targetScreen: NSScreen

        if let window = button.window,
           let screen = window.screen,
           screen.frame.contains(NSPoint(x: window.frame.midX, y: window.frame.midY)) {
            let frameInWindow = button.convert(button.bounds, to: nil)
            let candidate = window.convertToScreen(frameInWindow)
            if screen.frame.contains(NSPoint(x: candidate.midX, y: candidate.midY)) {
                buttonFrame = candidate
                targetScreen = screen
            } else {
                let mouse = NSEvent.mouseLocation
                buttonFrame = NSRect(x: mouse.x - 10, y: mouse.y - 4, width: 20, height: 22)
                targetScreen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? screen
            }
        } else {
            let mouse = NSEvent.mouseLocation
            buttonFrame = NSRect(x: mouse.x - 10, y: mouse.y - 4, width: 20, height: 22)
            targetScreen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        }

        showPanel(anchorFrame: buttonFrame, on: targetScreen, preferredEdge: .automatic)
    }

    private func showPanel(anchorFrame: NSRect, on screen: NSScreen, preferredEdge: FloatingPanelPreferredEdge) {
        appState.refreshNow(forceLyrics: false)
        let panelSize = measuredPanelSize(for: screen)
        panel.setContentSize(panelSize)
        let origin = FloatingPanelPlacement.origin(
            anchorFrame: anchorFrame,
            panelSize: panelSize,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            preferredEdge: preferredEdge
        )
        panel.setFrameOrigin(origin)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func measuredPanelSize(for screen: NSScreen) -> NSSize {
        // fittingSize returns 0 if the hosting view never laid out (panel created with
        // defer:true). Force a layout pass first so the first open is sized correctly.
        panel.contentViewController?.view.layoutSubtreeIfNeeded()
        let size = panel.contentViewController?.view.fittingSize ?? NSSize(width: 380, height: 360)
        let measuredHeight = size.height > 100 ? size.height : 360
        return NSSize(
            width: 380,
            height: max(280, min(screen.visibleFrame.height - 40, measuredHeight))
        )
    }

    private func closePanel() {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        }
    }

    private func showStatusMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Refresh Lyrics", action: #selector(refreshFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: appState.settings.hideLyrics ? "Show Lyrics" : "Hide Lyrics", action: #selector(toggleLyricsFromMenu), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit SpotLyrics Bar", action: #selector(quitFromMenu), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 3), in: button)
    }

    @objc private func refreshFromMenu() {
        appState.refreshNow(forceLyrics: true)
    }

    @objc private func toggleLyricsFromMenu() {
        appState.toggleLyricsVisibility()
    }

    @objc private func quitFromMenu() {
        NSApplication.shared.terminate(nil)
    }
}
