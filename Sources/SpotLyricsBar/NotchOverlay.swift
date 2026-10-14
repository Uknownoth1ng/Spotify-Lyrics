import AppKit
import SwiftUI
import Combine

/// Notch Overlay — replicates boring.notch's approach:
/// - NSPanel at `.mainMenu + 3` level (above menu bar)
/// - Positioned flush with the top of the built-in screen, centered
/// - Black background with a custom NotchShape (concave top corners, convex bottom)
/// - Compact state matches the physical notch dimensions
/// - Content extends the notch downward visually
@MainActor
final class NotchOverlayController {
    private var window: NSPanel?
    private weak var appState: AppState?
    private var observers: [AnyCancellable] = []
    private var pauseTimer: Timer?
    private var hiddenByUser = false
    private nonisolated(unsafe) var screenToken: Any?

    init(appState: AppState) {
        self.appState = appState

        appState.settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &observers)

        appState.$playback
            .receive(on: RunLoop.main)
            .removeDuplicates { $0.track?.stableKey == $1.track?.stableKey && $0.isPlaying == $1.isPlaying }
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &observers)

        screenToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }

        evaluate()
    }

    func hideByUser() {
        // Turn off the setting so the toggle in Settings reflects reality.
        appState?.settings.notchOverlayEnabled = false
        hide()
    }

    func unhide() {
        hiddenByUser = false
        evaluate()
    }

    func openLyricsPanel() {
        var userInfo: [AnyHashable: Any] = [:]
        if let window, window.isVisible, let screen = window.screen {
            userInfo[LyricsPanelAnchorNotificationKey.anchorFrame] = NSValue(rect: window.frame)
            userInfo[LyricsPanelAnchorNotificationKey.screenNumber] = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        }
        NotificationCenter.default.post(
            name: .openLyricsPanel,
            object: nil,
            userInfo: userInfo.isEmpty ? nil : userInfo
        )
    }

    private func evaluate() {
        guard let appState else { return }
        guard appState.settings.notchOverlayEnabled else {
            hide()
            // When the user re-enables via Settings, clear the session-hide flag
            // so the overlay actually appears again.
            hiddenByUser = false
            return
        }
        guard !hiddenByUser else { return }
        guard let screen = NotchDisplayDetector.builtInNotchScreen ?? NotchDisplayDetector.builtInScreen ?? NSScreen.main else { hide(); return }

        cancelPauseTimer()
        show(on: screen)
    }

    private func show(on screen: NSScreen) {
        guard let appState else { return }
        if window == nil {
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isMovable = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.ignoresMouseEvents = false
            panel.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
            panel.contentViewController = NSHostingController(
                rootView: NotchOverlayContentView(controller: self)
                    .environmentObject(appState)
            )
            window = panel
        }
        positionWindow(on: screen)
        window?.orderFrontRegardless()
    }

    private func hide() {
        window?.orderOut(nil)
    }

    private func positionWindow(on screen: NSScreen) {
        guard let window else { return }
        let notchInfo = notchDimensions(for: screen)
        let overlayWidth = notchInfo.width + 120
        // Give the window enough height for the expanded state. The SwiftUI view
        // uses a VStack with Spacer at the bottom, so compact content hugs the top
        // and expanded content grows downward. The window background is .clear so
        // the unused space is invisible.
        let maxHeight: CGFloat = 200
        let x = screen.frame.origin.x + (screen.frame.width / 2) - overlayWidth / 2
        let y = screen.frame.origin.y + screen.frame.height - maxHeight
        window.setFrame(NSRect(x: x, y: y, width: overlayWidth, height: maxHeight), display: true)
    }

    private func notchDimensions(for screen: NSScreen) -> (width: CGFloat, height: CGFloat) {
        // Use auxiliaryTopLeftArea / auxiliaryTopRightArea to compute notch width.
        if #available(macOS 12.0, *) {
            let topLeft = screen.auxiliaryTopLeftArea
            let topRight = screen.auxiliaryTopRightArea
            if let topLeft, let topRight {
                let leftPadding = topLeft.width + topLeft.origin.x - screen.frame.origin.x
                let rightPadding = (screen.frame.maxX - topRight.origin.x - topRight.width)
                    + topRight.width
                let notchWidth = screen.frame.width - leftPadding - rightPadding + 4
                let notchHeight = screen.safeAreaInsets.top
                return (max(180, notchWidth), max(32, notchHeight))
            }
            if screen.safeAreaInsets.top > 0 {
                return (180, screen.safeAreaInsets.top)
            }
        }
        return (180, 32)
    }

    private func schedulePauseHide() {
        guard pauseTimer == nil else { return }
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    private func cancelPauseTimer() {
        pauseTimer?.invalidate()
        pauseTimer = nil
    }
}

// MARK: - Notch Shape (boring.notch style)

/// Custom shape matching the MacBook notch silhouette: top corners curve inward
/// (concave, matching the notch "ears"), bottom corners round outward (convex).
private struct NotchShape: Shape {
    var topRadius: CGFloat = 8
    var bottomRadius: CGFloat = 14

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        let br = min(bottomRadius, h / 2, w / 4)

        // Start top-left, go clockwise.
        // Top edge is flush with the screen top (merges with notch).
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: w, y: 0))

        // Right edge → bottom-right corner (convex outward)
        path.addLine(to: CGPoint(x: w, y: h - br))
        path.addQuadCurve(
            to: CGPoint(x: w - br, y: h),
            control: CGPoint(x: w, y: h)
        )

        // Bottom edge
        path.addLine(to: CGPoint(x: br, y: h))

        // Bottom-left corner (convex outward)
        path.addQuadCurve(
            to: CGPoint(x: 0, y: h - br),
            control: CGPoint(x: 0, y: h)
        )

        path.closeSubpath()
        return path
    }
}

// MARK: - Content View

private struct NotchOverlayContentView: View {
    @EnvironmentObject var appState: AppState
    let controller: NotchOverlayController
    @State private var expanded = false
    @State private var hoverIntent = false
    @State private var collapseTask: Task<Void, Never>?

    private var currentLine: String? { appState.snapshot.current?.text }
    private var trackInfo: String {
        guard let track = appState.playback.track else { return "Open Spotify to start lyrics" }
        return "\(track.title) — \(track.displaySubtitle)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Content hugs the top of the window (flush with screen top / notch).
            VStack(spacing: 0) {
                topBar
                if expanded {
                    expandedContent
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .background(
                NotchShape(topRadius: 8, bottomRadius: expanded ? 20 : 14)
                    .fill(Color.black)
            )
            .onHover { hovering in
                if hovering {
                    collapseTask?.cancel()
                    collapseTask = nil
                    if !expanded {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
                            expanded = true
                        }
                    }
                } else {
                    collapseTask = Task {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            withAnimation(.spring(response: 0.45, dampingFraction: 1.0)) {
                                expanded = false
                            }
                        }
                    }
                }
            }
            .onTapGesture {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
                    expanded.toggle()
                }
            }
            .contextMenu {
                Button("Hide Notch Lyrics") { controller.hideByUser() }
                Button("Open Lyrics Panel") {
                    controller.openLyricsPanel()
                }
                Divider()
                Button("Settings...") { appState.showSettings() }
            }

            // Spacer pushes content to the top; unused space is transparent.
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Top bar: album art on left ear (only when NOT expanded), music bars on right ear.
    private var topBar: some View {
        HStack(spacing: 0) {
            // Left ear: small album art — hidden when expanded (large art takes over)
            if !expanded {
                Group {
                    if let urlString = appState.playback.track?.artworkURL,
                       let url = URL(string: urlString) {
                        AsyncImage(url: url, transaction: Transaction(animation: nil)) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            default:
                                Color.clear
                            }
                        }
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(.leading, 8)
                .padding(.vertical, 4)
            }

            Spacer()

            MusicBarsView(isPlaying: appState.playback.isPlaying)
                .frame(width: 16, height: 14)
                .padding(.trailing, 8)
                .padding(.vertical, 4)
        }
        .frame(height: 32)
    }

    /// Expanded content: appears BELOW the notch area on hover/click.
    /// Layout: large album art left + lyrics/track info right. No buttons.
    private var expandedContent: some View {
        HStack(alignment: .center, spacing: 16) {
            // Large album art — reuses the same URL as compact (already cached by
            // AsyncImage's internal URLSession cache, so no black flash).
            Group {
                if let urlString = appState.playback.track?.artworkURL,
                   let url = URL(string: urlString) {
                    AsyncImage(url: url, transaction: Transaction(animation: nil)) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            // Show nothing (transparent) instead of a black placeholder
                            // to avoid the flash. The image is almost certainly already
                            // cached from the compact-state thumbnail.
                            Color.clear
                        }
                    }
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                // Song title
                Text(appState.playback.track?.title ?? "SpotLyrics")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .lineLimit(1)

                // Artist
                Text(appState.playback.track?.displaySubtitle ?? "Open Spotify")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.50))
                    .lineLimit(1)

                // Current lyric — no truncation in expanded state
                if let line = currentLine {
                    Text(line)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.80))
                        .fixedSize(horizontal: false, vertical: true)
                        .id(line)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .animation(.easeOut(duration: 0.22), value: currentLine)
    }

    private var albumArt: some View {
        Group {
            if let urlString = appState.playback.track?.artworkURL,
               let url = URL(string: urlString) {
                AsyncImage(url: url, transaction: Transaction(animation: nil)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    }
                }
            } else {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

}
