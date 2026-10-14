import AppKit
import SwiftUI
import Combine

/// Controls the Notch Lyrics Capsule lifecycle. Created once at app launch;
/// shows/hides the capsule window based on settings + display state + playback.
@MainActor
final class NotchCapsuleController {
    private var window: NSWindow?
    private weak var appState: AppState?
    private var observers: [AnyCancellable] = []
    private var screenObserver: Any?
    private var pauseTimer: Timer?
    private var capsuleHiddenByUser = false
    private nonisolated(unsafe) var screenObserverToken: Any?

    init(appState: AppState) {
        self.appState = appState

        // Settings changes (toggle on/off). Debounce because objectWillChange fires
        // before the value commits.
        appState.settings.objectWillChange
            .receive(on: RunLoop.main)
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &observers)

        // Playback changes (track change, play/pause).
        appState.$playback
            .receive(on: RunLoop.main)
            .removeDuplicates { $0.track?.stableKey == $1.track?.stableKey && $0.isPlaying == $1.isPlaying }
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &observers)

        // Also observe lyricsStatus so capsule appears once lyrics are found.
        appState.$lyricsStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &observers)

        screenObserverToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }

        // Delayed initial evaluate — gives AppState time to fetch first playback.
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { self.evaluate() }
        }
    }

    deinit {
        if let token = screenObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func hideByUser() {
        // Turn off the setting so the toggle in Settings reflects reality.
        appState?.settings.notchLyricsEnabled = false
        hideCapsule()
    }

    func unhideByUser() {
        capsuleHiddenByUser = false
        evaluate()
    }

    private func evaluate() {
        guard let appState else { return }

        // Gate 1: user setting
        guard appState.settings.notchLyricsEnabled else {
            hideCapsule()
            capsuleHiddenByUser = false
            return
        }

        // Gate 2: user manually hid this session
        guard !capsuleHiddenByUser else { return }

        // Gate 3: prefer the built-in notch screen, but still show on the built-in
        // display or main screen when macOS reports no notch safe-area. The user
        // explicitly enabled the feature; don't silently hide it.
        guard let screen = NotchDisplayDetector.builtInNotchScreen ?? NotchDisplayDetector.builtInScreen ?? NSScreen.main else {
            hideCapsule()
            return
        }

        cancelPauseTimer()
        showCapsule(on: screen)
    }

    private func showCapsule(on screen: NSScreen) {
        guard let appState else { return }
        if window == nil {
            let w = NotchCapsuleWindow(appState: appState, controller: self)
            window = w
        }
        // Always reposition (the window may have been created with zero frame).
        positionWindow(on: screen)
        window?.orderFrontRegardless()

        // SwiftUI may not have laid out yet on first show. Re-position after a
        // short delay to pick up the real fittingSize.
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            await MainActor.run { self.positionWindow(on: screen) }
        }
    }

    private func hideCapsule() {
        window?.orderOut(nil)
    }

    private func positionWindow(on screen: NSScreen) {
        guard let window else { return }
        window.contentViewController?.view.layoutSubtreeIfNeeded()
        let fittingSize = window.contentViewController?.view.fittingSize ?? .zero
        // Use the user's configured width; height from fitting or default 36.
        let capsuleWidth = max(appState?.settings.capsuleWidth ?? 360, 260)
        let capsuleHeight = fittingSize.height > 20 ? fittingSize.height : 36
        let x = screen.frame.midX - capsuleWidth / 2
        let y = screen.visibleFrame.maxY - capsuleHeight
        window.setFrame(NSRect(x: x, y: y, width: capsuleWidth, height: capsuleHeight), display: true)
    }

    private func schedulePauseHide() {
        guard pauseTimer == nil else { return }
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.hideCapsule()
            }
        }
    }

    private func cancelPauseTimer() {
        pauseTimer?.invalidate()
        pauseTimer = nil
    }
}
