import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var menuBarMaxCharacters: Int {
        didSet { defaults.set(menuBarMaxCharacters, forKey: Keys.menuBarMaxCharacters) }
    }
    @Published var globalLatencyCompensationMs: Int {
        didSet { defaults.set(globalLatencyCompensationMs, forKey: Keys.globalLatencyCompensationMs) }
    }
    @Published var showLyricsSource: Bool {
        didSet { defaults.set(showLyricsSource, forKey: Keys.showLyricsSource) }
    }
    @Published var hideLyrics: Bool {
        didSet { defaults.set(hideLyrics, forKey: Keys.hideLyrics) }
    }
    @Published var displayMode: DisplayMode {
        didSet { defaults.set(displayMode.rawValue, forKey: Keys.displayMode) }
    }
    @Published var aiAutoExplainHighValueLines: Bool {
        didSet { defaults.set(aiAutoExplainHighValueLines, forKey: Keys.aiAutoExplainHighValueLines) }
    }
    @Published var notchLyricsEnabled: Bool {
        didSet { defaults.set(notchLyricsEnabled, forKey: Keys.notchLyricsEnabled) }
    }
    @Published var notchOverlayEnabled: Bool {
        didSet { defaults.set(notchOverlayEnabled, forKey: Keys.notchOverlayEnabled) }
    }
    @Published var capsuleWidth: CGFloat {
        didSet { defaults.set(Double(capsuleWidth), forKey: Keys.capsuleWidth) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let maxCharacters = defaults.integer(forKey: Keys.menuBarMaxCharacters)
        self.menuBarMaxCharacters = maxCharacters == 0 ? 42 : maxCharacters
        let compensation = defaults.object(forKey: Keys.globalLatencyCompensationMs) as? Int
        self.globalLatencyCompensationMs = compensation ?? 150
        self.showLyricsSource = defaults.object(forKey: Keys.showLyricsSource) as? Bool ?? true
        self.hideLyrics = defaults.object(forKey: Keys.hideLyrics) as? Bool ?? false
        self.displayMode = DisplayMode(rawValue: defaults.string(forKey: Keys.displayMode) ?? "") ?? .menuBar
        self.aiAutoExplainHighValueLines = defaults.object(forKey: Keys.aiAutoExplainHighValueLines) as? Bool ?? false
        self.notchLyricsEnabled = defaults.object(forKey: Keys.notchLyricsEnabled) as? Bool ?? false
        self.notchOverlayEnabled = defaults.object(forKey: Keys.notchOverlayEnabled) as? Bool ?? false
        self.capsuleWidth = CGFloat(defaults.object(forKey: Keys.capsuleWidth) as? Double ?? 360)
    }

    private enum Keys {
        static let menuBarMaxCharacters = "menuBarMaxCharacters"
        static let globalLatencyCompensationMs = "globalLatencyCompensationMs"
        static let showLyricsSource = "showLyricsSource"
        static let hideLyrics = "hideLyrics"
        static let displayMode = "displayMode"
        static let aiAutoExplainHighValueLines = "aiAutoExplainHighValueLines"
        static let notchLyricsEnabled = "notchLyricsEnabled"
        static let notchOverlayEnabled = "notchOverlayEnabled"
        static let capsuleWidth = "capsuleWidth"
    }
}
