import AppKit
import SwiftUI

struct PanelRootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            SpotifyDesign.background
            routedView
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.easeOut(duration: 0.16), value: appState.panelRoute)
    }

    @ViewBuilder
    private var routedView: some View {
        switch appState.panelRoute {
        case .lyrics:
            LyricsPanelView()
        case .settings:
            SettingsView()
        case .aiSettings:
            AISettingsView()
        }
    }
}

struct PanelTitleBar: View {
    let title: String
    var subtitle: String?
    var showBack: Bool = true
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showBack {
                Button("‹") { appState.showLyricsPanel() }
                    .buttonStyle(IconPanelButtonStyle())
                    .accessibilityLabel("Back")
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(SpotifyDesign.secondaryText)
                        .lineLimit(2)
                }
            }

            Spacer()

            Button("×") {
                // Close just the panel; Quit lives in the status-bar right-click menu.
                NSApp.windows.first(where: { $0 is LyricsFloatingPanel })?.close()
            }
            .buttonStyle(IconPanelButtonStyle())
            .accessibilityLabel("Close panel")
            .help("Close panel")
        }
    }
}
