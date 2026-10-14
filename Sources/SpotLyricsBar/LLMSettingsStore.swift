import Foundation

@MainActor
final class LLMSettingsStore: ObservableObject {
    @Published var provider: LLMProviderConfig {
        didSet { saveProvider() }
    }
    @Published var maskedAPIKey = "Not configured"
    @Published var lastTestMessage: String?

    private let defaults: UserDefaults
    private let keychain: APIKeychainStore
    private let providerKey = "llmProviderConfig"

    private let hasKeyFlag = "spotlyrics.hasAPIKey"
    private var cachedKey: String?

    init(defaults: UserDefaults = .standard, keychain: APIKeychainStore = APIKeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
        if let data = defaults.data(forKey: providerKey),
           var decoded = try? JSONDecoder().decode(LLMProviderConfig.self, from: data) {
            if decoded.reasoningEffort == "high" || decoded.reasoningEffort == nil {
                decoded.reasoningEffort = "low"
            }
            self.provider = decoded
        } else {
            self.provider = LLMProviderConfig(
                id: "timi_cc",
                name: "timi_cc",
                baseURL: URL(string: "https://timicc.com/v1")!,
                model: "gpt-5.5",
                wireAPI: .responses,
                reasoningEffort: "low",
                disableResponseStorage: true
            )
        }
        // DO NOT read the Keychain at launch. Doing so triggers the macOS Keychain
        // access prompt every time the unsigned binary's code identity changes, even
        // when the user just opened the menu bar app. Show whatever flag we have in
        // UserDefaults; the actual key is only read on demand (user opens AI Settings,
        // or the AI pipeline runs).
        if defaults.bool(forKey: hasKeyFlag) {
            maskedAPIKey = "Saved · open AI Settings to view"
        } else {
            maskedAPIKey = "Not configured"
        }
    }

    func setAPIKey(_ key: String) {
        do {
            try keychain.saveAPIKey(key, account: provider.id)
            cachedKey = key
            defaults.set(true, forKey: hasKeyFlag)
            refreshMaskedKey()
            lastTestMessage = "API Key saved in macOS Keychain."
        } catch {
            lastTestMessage = "Could not save API Key to Keychain."
        }
    }

    func apiKey() -> String? {
        if let cachedKey { return cachedKey }
        // Try reading from Keychain. The hasKeyFlag gates the common case (no key
        // configured at all), but we also try without the flag for users who saved
        // a key in an older version before the flag existed.
        let key = try? keychain.readAPIKey(account: provider.id)
        if let key, !key.isEmpty {
            cachedKey = key
            // Backfill the flag so future reads skip the Keychain entirely.
            defaults.set(true, forKey: hasKeyFlag)
            return key
        }
        return nil
    }

    func deleteAPIKey() {
        try? keychain.deleteAPIKey(account: provider.id)
        cachedKey = nil
        defaults.set(false, forKey: hasKeyFlag)
        maskedAPIKey = "Not configured"
        lastTestMessage = "API Key deleted."
    }

    func resetProvider() {
        provider = LLMProviderConfig(
            id: "openai",
            name: "openai",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            model: "gpt-5.5",
            wireAPI: .responses,
            reasoningEffort: "medium",
            disableResponseStorage: true
        )
        cachedKey = nil
        refreshMaskedKey()
    }

    func refreshMaskedKey() {
        // Now an explicit user-triggered action (Settings opened, key just saved).
        // Reading Keychain here is fine because the user is on-screen in the AI
        // Settings panel and expects authentication if it pops up.
        let key = try? keychain.readAPIKey(account: provider.id)
        cachedKey = key
        maskedAPIKey = APIKeychainStore.masked(key)
    }

    private func saveProvider() {
        if let data = try? JSONEncoder().encode(provider) {
            defaults.set(data, forKey: providerKey)
        }
        refreshMaskedKey()
    }
}
