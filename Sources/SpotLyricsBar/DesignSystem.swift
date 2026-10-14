import SwiftUI

enum SpotifyDesign {
    static let background = Color(red: 18 / 255, green: 18 / 255, blue: 18 / 255)
    static let surface = Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255)
    static let elevated = Color(red: 31 / 255, green: 31 / 255, blue: 31 / 255)
    static let primaryText = Color.white
    static let secondaryText = Color(red: 179 / 255, green: 179 / 255, blue: 179 / 255)
    static let green = Color(red: 29 / 255, green: 185 / 255, blue: 84 / 255)
    static let mutedGreen = Color(red: 30 / 255, green: 215 / 255, blue: 96 / 255)
    static let inputBackground = Color.white.opacity(0.08)
}

struct IconPanelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(SpotifyDesign.primaryText)
            .frame(width: 30, height: 26)
            .background(configuration.isPressed ? Color.white.opacity(0.18) : Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct PanelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(SpotifyDesign.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(configuration.isPressed ? SpotifyDesign.green.opacity(0.35) : Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Dark-mode Picker style that matches the app's visual language. Forces the
/// NSPopUpButton to render in dark appearance regardless of system setting.
struct DarkPickerStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .labelsHidden()
            .colorScheme(.dark)
    }
}

/// Animated pixel-grid music bars (like Spotify's "now playing" indicator).
/// 4 bars driven by TimelineView at display refresh rate for buttery smooth motion.
struct MusicBarsView: View {
    let isPlaying: Bool
    private let barCount = 4
    private let barWidth: CGFloat = 2.5
    private let spacing: CGFloat = 1.5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    let phase = Double(index) * 1.2
                    let speed = 2.8 + Double(index) * 0.6
                    let raw = isPlaying
                        ? 0.35 + 0.65 * abs(sin(t * speed + phase))
                        : 0.12
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(SpotifyDesign.mutedGreen)
                        .frame(width: barWidth, height: max(2, CGFloat(raw) * 14))
                }
            }
        }
    }
}

extension View {
    func darkPickerStyle() -> some View {
        modifier(DarkPickerStyle())
    }
}
