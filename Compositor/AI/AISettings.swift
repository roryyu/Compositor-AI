import Foundation
import Combine

/// What a configured AI endpoint is for. Vision covers chat, image analysis, and the
/// editing agent; Image covers text-to-image generation.
nonisolated enum AIConfigRole: String, CaseIterable, Sendable {
    case vision, image
    var label: String { self == .vision ? "Vision / Chat" : "Image Generation" }
    /// UserDefaults key prefix, e.g. "ai.vision.baseURL".
    var prefix: String { "ai.\(rawValue)" }
    /// Keychain account for the API key.
    var keychainAccount: String { "ai.\(rawValue).apiKey" }
}

/// Provider presets. Choosing one fills the base URL and hints the model name; the
/// fields stay editable for custom OpenAI-compatible services.
nonisolated enum ProviderPreset: String, CaseIterable, Codable, Sendable {
    case openai = "OpenAI"
    case deepseek = "DeepSeek"
    case dashscope = "Qwen (DashScope)"
    case zhipu = "Zhipu GLM"
    case moonshot = "Moonshot"
    case ark = "Volcengine Ark"
    case gemini = "Gemini"
    case ollama = "Ollama (Local)"
    case custom = "Custom"

    var defaultBaseURL: String {
        switch self {
        case .openai: "https://api.openai.com/v1"
        case .deepseek: "https://api.deepseek.com/v1"
        case .dashscope: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .zhipu: "https://open.bigmodel.cn/api/paas/v4"
        case .moonshot: "https://api.moonshot.cn/v1"
        case .ark: "https://ark.cn-beijing.volces.com/api/v3"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .ollama: "http://localhost:11434/v1"
        case .custom: ""
        }
    }

    /// Suggested model, shown as placeholder text only.
    func suggestedModel(for role: AIConfigRole) -> String {
        switch self {
        case .openai: role == .vision ? "gpt-4o" : "gpt-image-1"
        case .deepseek: "deepseek-chat"
        case .dashscope: role == .vision ? "qwen-vl-max" : "wanx2.1-t2i-turbo"
        case .zhipu: "glm-4v"
        case .moonshot: "moonshot-v1-8k-vision-preview"
        case .ark: role == .vision ? "doubao-seed-1-6-vision" : "doubao-seedream-4-0"
        case .gemini: role == .vision ? "gemini-2.5-flash" : "gemini-2.5-flash-image"
        case .ollama: "llava"
        case .custom: ""
        }
    }
}

/// One endpoint's configuration. The API key lives only in the Keychain.
nonisolated struct AIProviderConfig: Codable, Equatable, Sendable {
    var baseURL: String
    var model: String
    var preset: ProviderPreset

    init(preset: ProviderPreset, role: AIConfigRole) {
        self.baseURL = preset.defaultBaseURL
        self.model = ""
        self.preset = preset
    }

    /// The request URL or nil when the base URL is not usable.
    var cleanedBaseURL: String? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" else { return nil }
        return trimmed
    }

    var isUsable: Bool { cleanedBaseURL != nil && !model.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// Loads and saves both AI configurations. UserDefaults for URLs and model names,
/// the Keychain for API keys.
@MainActor
final class AISettingsStore: ObservableObject {
    static let shared = AISettingsStore()

    @Published private(set) var vision: AIProviderConfig
    @Published private(set) var image: AIProviderConfig

    private let defaults: UserDefaults
    private let keychain: any KeychainStore

    init(defaults: UserDefaults = .standard, keychain: any KeychainStore = SystemKeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
        vision = Self.load(.vision, defaults: defaults)
        image = Self.load(.image, defaults: defaults)
    }

    private static func load(_ role: AIConfigRole, defaults: UserDefaults) -> AIProviderConfig {
        if let data = defaults.data(forKey: role.prefix + ".config"),
           let config = try? JSONDecoder().decode(AIProviderConfig.self, from: data) {
            return config
        }
        return AIProviderConfig(preset: .openai, role: role)
    }

    private func save(_ role: AIConfigRole, _ config: AIProviderConfig) {
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: role.prefix + ".config")
        }
    }

    func update(_ role: AIConfigRole, _ change: (inout AIProviderConfig) -> Void) {
        switch role {
        case .vision:
            var config = vision; change(&config); vision = config; save(role, config)
        case .image:
            var config = image; change(&config); image = config; save(role, config)
        }
    }

    /// Switching preset fills in the preset's base URL and clears the model.
    func choosePreset(_ preset: ProviderPreset, for role: AIConfigRole) {
        update(role) {
            $0.preset = preset
            $0.baseURL = preset.defaultBaseURL
            $0.model = ""
        }
    }

    func apiKey(_ role: AIConfigRole) -> String {
        (try? keychain.read(account: role.keychainAccount)) ?? nil ?? ""
    }

    func setAPIKey(_ role: AIConfigRole, _ value: String) {
        try? keychain.write(value.isEmpty ? nil : value, account: role.keychainAccount)
    }

    /// A transport for chat requests against the given role's configuration.
    func makeTransport(_ role: AIConfigRole) throws -> OpenAICompatTransport {
        let config = role == .vision ? vision : image
        guard let base = config.cleanedBaseURL else {
            throw AIError.notConfigured("\(role.label) base URL")
        }
        let model = config.model.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { throw AIError.notConfigured("\(role.label) model") }
        let key = apiKey(role)
        return OpenAICompatTransport(baseURL: base, model: model, apiKey: key.isEmpty ? nil : key)
    }

    /// Whether the menu should offer the given feature at all.
    func isConfigured(_ role: AIConfigRole) -> Bool {
        let config = role == .vision ? vision : image
        return config.isUsable
    }
}
