import SwiftUI

/// The AI Settings panel: separate Vision/Chat and Image Generation configurations.
struct AISettingsSheet: View {
    @ObservedObject var store: AISettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProviderSection(role: .vision, store: store)
            Divider().padding(.vertical, 8)
            ProviderSection(role: .image, store: store)
        }
        .padding(16)
        .frame(width: 460)
    }
}

private struct ProviderSection: View {
    let role: AIConfigRole
    @ObservedObject var store: AISettingsStore

    @State private var key = ""
    @State private var revealsKey = false
    @State private var testState: TestState = .idle

    private var config: AIProviderConfig {
        role == .vision ? store.vision : store.image
    }

    enum TestState: Equatable {
        case idle, testing, ok, failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(role.label)
                .font(.headline)
            HStack {
                Text("Provider").frame(width: 80, alignment: .leading)
                Picker("", selection: Binding(
                    get: { config.preset },
                    set: { store.choosePreset($0, for: role) })) {
                    ForEach(ProviderPreset.allCases, id: \.self) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220)
            }
            labeled("Base URL") {
                TextField("https://…", text: Binding(
                    get: { config.baseURL },
                    set: { value in store.update(role) { $0.baseURL = value } }))
            }
            labeled("Model") {
                TextField(config.preset.suggestedModel(for: role), text: Binding(
                    get: { config.model },
                    set: { value in store.update(role) { $0.model = value } }))
            }
            labeled("API Key") {
                Group {
                    if revealsKey {
                        TextField("required (except local models)", text: $key)
                    } else {
                        SecureField("required (except local models)", text: $key)
                    }
                }
                Button {
                    revealsKey.toggle()
                } label: {
                    Image(systemName: revealsKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealsKey ? "Hide key" : "Show key")
            }
            HStack(spacing: 10) {
                Button("Test Connection") { test() }
                    .disabled(testState == .testing)
                switch testState {
                case .idle:
                    EmptyView()
                case .testing:
                    ProgressView().controlSize(.small)
                case .ok:
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                case .failed(let message):
                    Label(message, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .lineLimit(2)
                }
            }
        }
        .onAppear { key = store.apiKey(role) }
        .onChange(of: key) { _, newValue in
            store.setAPIKey(role, newValue)
        }
    }

    private func labeled(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).frame(width: 80, alignment: .leading)
            content()
        }
    }

    private func test() {
        testState = .testing
        Task {
            do {
                if role == .vision {
                    let transport = try store.makeTransport(role)
                    try await VisionService(transport: transport).testConnection()
                } else {
                    // Image endpoints are billed per image: validate the configuration without generating.
                    let config = role == .image ? store.image : store.vision
                    guard config.isUsable else { throw AIError.notConfigured("base URL and model") }
                    if store.apiKey(role).isEmpty, config.preset != .ollama {
                        throw AIError.notConfigured("API key")
                    }
                }
                testState = .ok
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}
