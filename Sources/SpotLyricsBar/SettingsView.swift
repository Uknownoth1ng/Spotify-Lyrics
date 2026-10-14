import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var spDcCookie = ""
    @State private var spDcSaved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PanelTitleBar(title: "Settings", subtitle: "Keep the menu bar quiet and synced.")

            section(header: "Display") {
                rowDivider {
                    settingRow("Notch Lyrics Capsule") {
                        Toggle("", isOn: Binding(
                            get: { appState.settings.notchLyricsEnabled },
                            set: { appState.settings.notchLyricsEnabled = $0 }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                    settingRow("Dynamic Island ᴱˣᵖ") {
                        Toggle("", isOn: Binding(
                            get: { appState.settings.notchOverlayEnabled },
                            set: { appState.settings.notchOverlayEnabled = $0 }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                    if appState.settings.notchLyricsEnabled || appState.settings.notchOverlayEnabled {
                        Text(NotchDisplayDetector.hasBuiltInNotchDisplay
                            ? "Capsule floats below the notch. Dynamic Island merges into the notch."
                            : "No built-in notch display detected. Menu Bar Lyrics still works.")
                            .font(.system(size: 11))
                            .foregroundStyle(SpotifyDesign.secondaryText)
                            .padding(.vertical, 4)
                    }
                    settingRow("Show lyrics source") {
                        Toggle("", isOn: Binding(
                            get: { appState.settings.showLyricsSource },
                            set: { appState.settings.showLyricsSource = $0 }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                    settingRow("Hide lyrics temporarily") {
                        Toggle("", isOn: Binding(
                            get: { appState.settings.hideLyrics },
                            set: { appState.settings.hideLyrics = $0 }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
            }

            section(header: "Timing") {
                rowDivider {
                    sliderRow(
                        title: "Menu length",
                        value: Binding(
                            get: { Double(appState.settings.menuBarMaxCharacters) },
                            set: { appState.settings.menuBarMaxCharacters = Int($0) }
                        ),
                        range: 18...120,
                        step: 1,
                        format: { "\(Int($0)) chars" }
                    )
                    sliderRow(
                        title: "Latency",
                        value: Binding(
                            get: { Double(appState.settings.globalLatencyCompensationMs) },
                            set: { appState.settings.globalLatencyCompensationMs = Int($0) }
                        ),
                        range: -800...800,
                        step: 25,
                        format: { String(format: "%+d ms", Int($0)) }
                    )
                }
            }

            section(header: "Podcast Transcript") {
                settingRow("Spotify sp_dc") {
                    SecureField("Paste sp_dc cookie", text: $spDcCookie)
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 8) {
                    Button("Save") {
                        try? APIKeychainStore().saveAPIKey(spDcCookie, account: "spotify_sp_dc")
                        spDcCookie = ""
                        spDcSaved = true
                    }
                    .buttonStyle(PanelButtonStyle())
                    .disabled(spDcCookie.isEmpty)
                    if spDcSaved {
                        Text("Saved").font(.system(size: 11)).foregroundStyle(SpotifyDesign.green)
                    }
                }
                Text("Get from browser: open.spotify.com → DevTools → Application → Cookies → sp_dc")
                    .font(.system(size: 10))
                    .foregroundStyle(SpotifyDesign.secondaryText.opacity(0.7))
            }

            section(header: "Maintenance") {
                HStack(spacing: 8) {
                    Button { appState.clearCache() } label: {
                        Label("Clear Cache", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PanelButtonStyle())
                    Button { appState.refreshNow(forceLyrics: true) } label: {
                        Label("Refresh Now", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PanelButtonStyle())
                }
            }

            HStack {
                Spacer()
                Text("Made by zachwk05@gmail.com")
                    .font(.system(size: 10))
                    .foregroundStyle(SpotifyDesign.secondaryText.opacity(0.5))
                Spacer()
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(SpotifyDesign.background)
        .foregroundStyle(SpotifyDesign.primaryText)
        .preferredColorScheme(.dark)
        .tint(SpotifyDesign.green)
    }

    @ViewBuilder
    private func section<Content: View>(header: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(header.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(SpotifyDesign.secondaryText)
                .padding(.bottom, 6)
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(SpotifyDesign.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func settingRow<Content: View>(_ title: String, @ViewBuilder control: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SpotifyDesign.primaryText)
                .frame(minWidth: 130, alignment: .leading)
            Spacer(minLength: 0)
            control()
        }
        .frame(minHeight: 30)
        .padding(.vertical, 6)
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: @escaping (Double) -> String
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SpotifyDesign.primaryText)
                .frame(minWidth: 120, alignment: .leading)
            Slider(value: value, in: range, step: step)
                .frame(maxWidth: .infinity)
            Text(format(value.wrappedValue))
                .font(.system(size: 11, weight: .regular).monospacedDigit())
                .foregroundStyle(SpotifyDesign.secondaryText)
                .frame(width: 64, alignment: .trailing)
        }
        .frame(minHeight: 30)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func rowDivider<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            VStack(spacing: 0) {
                Color.clear
                Divider()
                    .overlay(Color.white.opacity(0.06))
            }
        )
    }
}

struct AISettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var baseURLText = ""
    @State private var isTesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelTitleBar(title: "AI English", subtitle: "Optional. API keys stay in Keychain.")
            Text("Optional. Lyrics display works without AI. Only the current line and nearby context are sent when you click Explain.")
                .font(.system(size: 12))
                .foregroundStyle(SpotifyDesign.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 0) {
                    formRow("Provider") {
                        TextField("timi_cc", text: Binding(
                            get: { appState.llmSettings.provider.name },
                            set: { appState.llmSettings.provider.name = $0 }
                        ))
                    }
                    formRow("ID") {
                        TextField("timi_cc", text: Binding(
                            get: { appState.llmSettings.provider.id },
                            set: { appState.llmSettings.provider.id = $0 }
                        ))
                    }
                    formRow("URL") {
                        TextField("https://api.openai.com/v1", text: $baseURLText)
                            .onSubmit { commitBaseURL() }
                    }
                    formRow("Model") {
                        TextField("gpt-5.5", text: Binding(
                            get: { appState.llmSettings.provider.model },
                            set: { appState.llmSettings.provider.model = $0 }
                        ))
                    }
                    formRow("Wire API") {
                        Picker("", selection: Binding(
                            get: { appState.llmSettings.provider.wireAPI },
                            set: { appState.llmSettings.provider.wireAPI = $0 }
                        )) {
                            ForEach(WireAPI.allCases) { api in
                                Text(api.label).tag(api)
                            }
                        }
                        .darkPickerStyle()
                    }
                    formRow("Effort") {
                        Picker("", selection: Binding(
                            get: { appState.llmSettings.provider.reasoningEffort ?? "low" },
                            set: { appState.llmSettings.provider.reasoningEffort = $0 }
                        )) {
                            Text("low").tag("low")
                            Text("medium").tag("medium")
                            Text("high").tag("high")
                        }
                        .darkPickerStyle()
                    }
                    formRow("No storage") {
                        Toggle("", isOn: Binding(
                            get: { appState.llmSettings.provider.disableResponseStorage },
                            set: { appState.llmSettings.provider.disableResponseStorage = $0 }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                    formRow("API Key") {
                        SecureField("Paste key", text: $apiKey)
                    }
                    HStack {
                        Text("Saved key")
                            .foregroundStyle(SpotifyDesign.secondaryText)
                        Spacer()
                        Text(appState.llmSettings.maskedAPIKey)
                            .lineLimit(1)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                }
                .background(SpotifyDesign.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .frame(height: 218)

            HStack(spacing: 7) {
                Button("Save API Key") {
                    guard !apiKey.isEmpty else { return }
                    appState.llmSettings.setAPIKey(apiKey)
                    apiKey = ""
                }
                Button("Delete API Key") { appState.llmSettings.deleteAPIKey() }
                Button("Reset Provider") {
                    appState.llmSettings.resetProvider()
                    baseURLText = appState.llmSettings.provider.baseURL.absoluteString
                }
                Spacer()
                Button(isTesting ? "Testing..." : "Test Connection") {
                    testConnection()
                }
                .disabled(isTesting)
            }
            .buttonStyle(PanelButtonStyle())

            if let message = appState.llmSettings.lastTestMessage {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(message.lowercased().contains("works") || message.lowercased().contains("saved") ? SpotifyDesign.green : .orange)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(SpotifyDesign.background)
        .foregroundStyle(SpotifyDesign.primaryText)
        .preferredColorScheme(.dark)
        .onAppear {
            baseURLText = appState.llmSettings.provider.baseURL.absoluteString
        }
        .onChange(of: baseURLText) {
            commitBaseURL()
        }
    }

    private func formRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SpotifyDesign.secondaryText)
                .frame(width: 76, alignment: .leading)
            content()
                .font(.system(size: 12))
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .foregroundStyle(SpotifyDesign.primaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.leading, 10)
        }
    }

    private func commitBaseURL() {
        guard let url = URL(string: baseURLText), url.scheme?.hasPrefix("http") == true else { return }
        appState.llmSettings.provider.baseURL = url
    }

    private func testConnection() {
        isTesting = true
        Task {
            let service = EnglishLearningService(settings: appState.llmSettings, cacheService: appState.cache)
            let message = await service.testConnection()
            await MainActor.run {
                appState.llmSettings.lastTestMessage = message
                isTesting = false
                if message.lowercased().contains("works") {
                    appState.showLyricsPanel()
                    appState.refreshNow(forceLyrics: true)
                }
            }
        }
    }
}
