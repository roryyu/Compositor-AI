import SwiftUI

/// The Edit with AI panel: instruction input, the running step timeline, and Stop/result.
struct AIPanelView: View {
    let modelName: String
    @ObservedObject var agent: EditAgent
    @State private var instruction = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit with AI")
                .font(.headline)
            Text(modelName)
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $instruction)
                .font(.body)
                .frame(height: 76)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Button("Run") {
                    agent.run(instruction)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(agent.isRunning || instruction.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Stop") { agent.stop() }
                    .disabled(!agent.isRunning)
            }
            if !agent.steps.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(agent.steps) { step in
                            StepRow(step: step)
                        }
                    }
                }
                .frame(height: 180)
            }
            if let summary = agent.summary {
                Text(summary)
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.green.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if let errorMessage = agent.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

private struct StepRow: View {
    let step: AgentStep

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: step.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(step.success ? Color.green : Color.red)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(step.tool)
                        .font(.callout.monospaced())
                    Text(step.duration.formatted(.units(allowed: [.seconds, .milliseconds])))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if step.argumentsSummary != "—" {
                    Text(step.argumentsSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(step.message)
                    .font(.caption2)
                    .foregroundStyle(step.success ? Color.secondary : Color.red)
                    .lineLimit(3)
            }
        }
    }
}

/// Opens and owns the four AI panels. Panel contents are rebuilt on each open so they
/// capture the current document and configuration.
@MainActor
final class AIPanels {
    static let shared = AIPanels()

    private let settingsPanel = FloatingPanelController(name: "aiSettings")
    private let generatePanel = FloatingPanelController(name: "aiGenerate")
    private let analyzePanel = FloatingPanelController(name: "aiAnalyze")
    private let agentPanel = FloatingPanelController(name: "aiAgent")

    private init() {}

    // MARK: Settings

    func showSettings() {
        settingsPanel.show(title: "AI Settings", content: AISettingsSheet(store: .shared))
    }

    // MARK: Generate image

    func showGenerate(session: EditorSession, initialPrompt: String = "") {
        do {
            let (service, modelName) = try imageService()
            let sheet = GenerateImageSheet(
                modelName: modelName,
                canvasSize: session.document?.size,
                initialPrompt: initialPrompt,
                fetch: { prompt, width, height, count in
                    try await service.generate(
                        ImageGenRequest(prompt: prompt, width: width, height: height, count: count))
                },
                insert: { images in
                    for image in images { session.aiInsert(image) }
                })
            generatePanel.show(title: "Generate Image", content: sheet)
        } catch {
            showSettings()
        }
    }

    // MARK: Analyze

    func showAnalyze(session: EditorSession) {
        do {
            let (transport, modelName) = try visionTransport()
            let sheet = AnalyzeCanvasSheet(
                modelName: modelName,
                prepareImage: {
                    try Self.canvasImage(session: session)
                },
                ask: { image, question in
                    try await VisionService(transport: transport).analyze(image: image, question: question)
                },
                useAsGeneratePrompt: { prompt in
                    self.showGenerate(session: session, initialPrompt: prompt)
                })
            analyzePanel.show(title: "Analyze Canvas", content: sheet)
        } catch {
            showSettings()
        }
    }

    // MARK: Edit agent

    func showAgent(session: EditorSession) {
        do {
            let (transport, modelName) = try visionTransport()
            var generator: AIToolDispatcher.Generator?
            if let (service, _) = try? imageService() {
                let size = session.document?.size ?? CGSize(width: 1024, height: 1024)
                generator = { prompt in
                    try await service.generate(
                        ImageGenRequest(prompt: prompt, width: Int(size.width), height: Int(size.height), count: 1))
                }
            }
            let agent = EditAgent(session: session, transport: transport, generator: generator)
            agentPanel.show(title: "Edit with AI", content: AIPanelView(modelName: modelName, agent: agent))
        } catch {
            showSettings()
        }
    }

    // MARK: Configuration helpers

    private func imageService() throws -> (ImageGenerationService, String) {
        let store = AISettingsStore.shared
        let config = store.image
        guard let base = config.cleanedBaseURL else { throw AIError.notConfigured("an image base URL") }
        let model = config.model.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { throw AIError.notConfigured("an image model") }
        let key = store.apiKey(.image)
        guard let adapter = ImageGenAdapterFactory.make(preset: config.preset, baseURL: base,
                                                        model: model,
                                                        apiKey: key.isEmpty ? nil : key) else {
            throw AIError.notConfigured("image generation for \(config.preset.rawValue)")
        }
        return (ImageGenerationService(adapter: adapter), "\(config.preset.rawValue) · \(model)")
    }

    private func visionTransport() throws -> (any ChatTransport, String) {
        let store = AISettingsStore.shared
        let transport = try store.makeTransport(.vision)
        return (transport, "\(store.vision.preset.rawValue) · \(store.vision.model)")
    }

    /// Composites the whole canvas, the same image the subject selection uses.
    private static func canvasImage(session: EditorSession) throws -> CGImage {
        guard let document = session.document else { throw AIError.noDocument }
        let context = try BrushRaster.context(width: document.width, height: document.height, mask: false)
        session.drawLiveComposite(document, in: context)
        guard let image = context.makeImage() else { throw AIError.imageFailed("the canvas could not be composited.") }
        return image
    }
}

extension EditorSession {
    /// Inserts one AI-generated image, keeping it inside the document limits.
    func aiInsert(_ image: CGImage, name: String? = nil) {
        let prepared: CGImage
        do {
            prepared = try ImageCodec.clampedToDocumentLimits(image)
        } catch {
            return
        }
        guard let thumbnail = try? PixelAdjust.thumbnail(of: prepared) else { return }
        insert(ImportedImage(image: prepared, thumbnail: thumbnail, name: name ?? nextAIImageName()))
    }

    func nextAIImageName() -> String {
        let names = Set(document?.layers.map(\.name) ?? [])
        var number = 1
        while names.contains("AI Image \(number)") { number += 1 }
        return "AI Image \(number)"
    }
}
