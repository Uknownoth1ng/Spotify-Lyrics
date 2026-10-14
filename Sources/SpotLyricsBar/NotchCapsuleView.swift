import AppKit
import SwiftUI

final class NotchCapsuleWindow: NSWindow {
    init(appState: AppState, controller: NotchCapsuleController) {
        let frame = NSRect(x: 0, y: 0, width: 340, height: 36)
        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        animationBehavior = .utilityWindow

        let host = NSHostingController(
            rootView: NotchCapsuleView(controller: controller)
                .environmentObject(appState)
        )
        contentViewController = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Capsule States

private enum CapsuleMode {
    case compact
    case hover
    case richCard
}

// MARK: - Main View

struct NotchCapsuleView: View {
    @EnvironmentObject var appState: AppState
    let controller: NotchCapsuleController
    @State private var mode: CapsuleMode = .compact
    @State private var longPressTimer: Timer?
    @State private var collapseTask: Task<Void, Never>?

    private var currentLine: String? { appState.snapshot.current?.text }
    private var previousLine: String? { appState.snapshot.previous.last?.text }
    private var nextLine: String? { appState.snapshot.next.first?.text }
    private var trackInfo: String {
        guard let track = appState.playback.track else { return "Open Spotify to start lyrics" }
        return "\(track.title) — \(track.displaySubtitle)"
    }

    var body: some View {
        VStack(spacing: 0) {
            switch mode {
            case .compact:
                compactBody
            case .hover:
                hoverBody
            case .richCard:
                richCardBody
            }
        }
        .frame(width: capsuleWidth, height: capsuleHeight)
        .background(capsuleBackground)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(alignment: .trailing) {
            // Right-edge drag handle for user to resize capsule width.
            CapsuleResizeHandle(width: Binding(
                get: { appState.settings.capsuleWidth },
                set: { appState.settings.capsuleWidth = $0 }
            ))
        }
        .shadow(color: .black.opacity(0.30), radius: 16, y: 6)
        .onHover { hovering in
            if hovering {
                collapseTask?.cancel()
                collapseTask = nil
                if mode == .compact { withAnimation(.easeOut(duration: 0.16)) { mode = .hover } }
            } else {
                // Debounce collapse to prevent jitter from view resize.
                collapseTask = Task {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        if mode == .hover { withAnimation(.easeOut(duration: 0.14)) { mode = .compact } }
                        if mode == .richCard { withAnimation(.easeOut(duration: 0.18)) { mode = .compact } }
                    }
                }
            }
        }
        .onTapGesture { openLyricsPanel() }
        .onLongPressGesture(minimumDuration: 0.4) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { mode = .richCard }
        }
        .contextMenu { contextMenu }
        .animation(.spring(response: 0.38, dampingFraction: 0.88), value: mode)
        .animation(.spring(response: 0.38, dampingFraction: 0.88), value: currentLine)
    }

    // MARK: - Compact (default)

    private var compactBody: some View {
        HStack(spacing: 8) {
            albumThumbnail(size: 24)
                .frame(width: 24, height: 24)
            playingIndicator
                .frame(width: 14)
            // Lyric area takes all remaining space, left-aligned, never shifts.
            Group {
                if let line = currentLine {
                    Text(line)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .lineLimit(1)
                        .id(line)
                        .transition(.asymmetric(
                            insertion: .opacity,
                            removal: .opacity
                        ))
                } else {
                    Text("♪ \(appState.playback.track?.title ?? "SpotLyrics")")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.50))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Hover (expanded)

    private var hoverBody: some View {
        VStack(spacing: 3) {
            HStack(spacing: 8) {
                albumThumbnail(size: 28)
                playingIndicator
                if let line = currentLine {
                    Text(line)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.95))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("♪ \(appState.playback.track?.title ?? "SpotLyrics")")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
                Spacer(minLength: 0)
                Button("Hide") { controller.hideByUser() }
                    .buttonStyle(CapsulePillButtonStyle())
            }
            HStack {
                Text(trackInfo)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Rich Card (long press)

    private var richCardBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Previous line
            if let prev = previousLine {
                Text(prev)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .lineLimit(1)
            }
            // Current line
            HStack(spacing: 6) {
                playingIndicator
                Text(currentLine ?? "—")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Next line
            if let next = nextLine {
                Text(next)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .lineLimit(1)
            }
            Divider().overlay(Color.white.opacity(0.08))
            // Track info + actions
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.playback.track?.title ?? "SpotLyrics")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.75))
                        .lineLimit(1)
                    Text(appState.playback.track?.displaySubtitle ?? "Open Spotify")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button("Explain") { appState.explainCurrentLine() }
                    .buttonStyle(CapsulePillButtonStyle())
                Button("Panel") { openLyricsPanel() }
                    .buttonStyle(CapsulePillButtonStyle())
                Button("Hide") { controller.hideByUser() }
                    .buttonStyle(CapsulePillButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private func albumThumbnail(size: CGFloat) -> some View {
        Group {
            if let urlString = appState.playback.track?.artworkURL,
               let url = URL(string: urlString) {
                AsyncImage(url: url, transaction: Transaction(animation: nil)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    }
                }
            } else {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var playingIndicator: some View {
        MusicBarsView(isPlaying: appState.playback.isPlaying)
            .frame(width: 14, height: 14)
    }

    private var capsuleWidth: CGFloat {
        // User-defined width (draggable from right edge). Stored in settings.
        let userWidth = appState.settings.capsuleWidth
        switch mode {
        case .compact: return userWidth
        case .hover: return userWidth + 20
        case .richCard: return max(userWidth, 400)
        }
    }

    private var capsuleHeight: CGFloat {
        switch mode {
        case .compact: return 36
        case .hover: return 52
        case .richCard: return 160
        }
    }

    private var cornerRadius: CGFloat {
        switch mode {
        case .compact: return 18
        case .hover: return 20
        case .richCard: return 16
        }
    }

    private var capsuleBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.40))
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Hide Notch Lyrics") { controller.hideByUser() }
        Button("Open Lyrics Panel") { openLyricsPanel() }
        Divider()
        Button("Settings...") { appState.showSettings() }
    }

    private func openLyricsPanel() {
        var userInfo: [AnyHashable: Any] = [:]
        if let window = NSApp.windows.first(where: { $0 is NotchCapsuleWindow }),
           window.isVisible,
           let screen = window.screen {
            userInfo[LyricsPanelAnchorNotificationKey.anchorFrame] = NSValue(rect: window.frame)
            userInfo[LyricsPanelAnchorNotificationKey.screenNumber] = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        }
        NotificationCenter.default.post(
            name: .openLyricsPanel,
            object: nil,
            userInfo: userInfo.isEmpty ? nil : userInfo
        )
    }
}

private struct CapsulePillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 1.0 : 0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.18 : 0.10))
            )
    }
}

/// Invisible right-edge drag handle that lets the user resize the capsule width.
private struct CapsuleResizeHandle: View {
    @Binding var width: CGFloat
    @State private var startWidth: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: 10)
            .frame(maxHeight: .infinity)
            .onContinuousHover { phase in
                switch phase {
                case .active: NSCursor.resizeLeftRight.set()
                case .ended: NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        if startWidth == 0 { startWidth = width }
                        let newWidth = max(260, min(600, startWidth + value.translation.width))
                        width = newWidth
                    }
                    .onEnded { _ in startWidth = 0 }
            )
    }
}

extension Notification.Name {
    static let openLyricsPanel = Notification.Name("SpotLyrics.openLyricsPanel")
}
