import SwiftUI

/// Generates images from a prompt and inserts each one as a layer.
struct GenerateImageSheet: View {
    let modelName: String
    let canvasSize: CGSize?
    let initialPrompt: String
    /// Fetches image bytes off the main actor.
    let fetch: @Sendable (String, Int, Int, Int) async throws -> [CGImage]
    /// Inserts decoded images on the main actor.
    let insert: ([CGImage]) -> Void

    enum SizeChoice: String, CaseIterable {
        case matchCanvas = "Match Canvas"
        case square = "Square 1:1"
        case landscape = "Landscape 3:2"
        case portrait = "Portrait 2:3"
    }

    @State private var prompt = ""
    @State private var sizeChoice: SizeChoice = .matchCanvas
    @State private var count = 1
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Generate Image")
                .font(.headline)
            Text(modelName)
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $prompt)
                .font(.body)
                .frame(height: 110)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Picker("Size", selection: $sizeChoice) {
                    ForEach(SizeChoice.allCases, id: \.self) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 180)
                Stepper("Images: \(count)", value: $count, in: 1...4)
                    .fixedSize()
            }
            if isWorking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Generating…")
                        .foregroundStyle(.secondary)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Generate") { generate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                Button("Cancel") {
                    task?.cancel()
                    if isWorking { task = nil }
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear {
            if !initialPrompt.isEmpty { prompt = initialPrompt }
        }
    }

    private var targetSize: (width: Int, height: Int) {
        let canvas = canvasSize ?? CGSize(width: 1024, height: 1024)
        switch sizeChoice {
        case .matchCanvas:
            let width = max(1, Int(canvas.width.rounded())), height = max(1, Int(canvas.height.rounded()))
            return (width, height)
        case .square: return (1024, 1024)
        case .landscape: return (1536, 1024)
        case .portrait: return (1024, 1536)
        }
    }

    private func generate() {
        errorMessage = nil
        isWorking = true
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let size = targetSize
        task = Task { @MainActor in
            do {
                let images = try await fetch(prompt, size.width, size.height, count)
                insert(images)
                isWorking = false
            } catch is CancellationError {
                isWorking = false
            } catch let error as AIError where error == .cancelled {
                isWorking = false
            } catch {
                errorMessage = error.localizedDescription
                isWorking = false
            }
        }
    }
}

/// Asks the vision model about the canvas; the answer can be copied or pushed into the
/// Generate Image prompt.
struct AnalyzeCanvasSheet: View {
    let modelName: String
    /// Builds the canvas image on the main actor before the network call.
    let prepareImage: () throws -> CGImage
    /// Runs the vision question off the main actor.
    let ask: @Sendable (CGImage, String) async throws -> String
    /// Opens Generate Image with the produced prompt.
    let useAsGeneratePrompt: (String) -> Void

    @State private var question = "Describe this image: its main subject, composition, and colors."
    @State private var answer: String?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Analyze Canvas")
                .font(.headline)
            Text(modelName)
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Question", text: $question)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                Text(answer ?? "")
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 160)
            .padding(8)
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            if isWorking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Thinking…").foregroundStyle(.secondary)
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button("Ask") { askAction() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
                Button("Copy") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(answer ?? "", forType: .string)
                }
                .disabled(answer == nil)
                Button("Use as Generate Prompt") {
                    if let answer { useAsGeneratePrompt(answer) }
                }
                .disabled(answer == nil)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func askAction() {
        errorMessage = nil
        answer = nil
        isWorking = true
        let question = question
        let image: CGImage
        do {
            image = try prepareImage()
        } catch {
            errorMessage = error.localizedDescription
            isWorking = false
            return
        }
        task = Task { @MainActor in
            do {
                answer = try await ask(image, question)
                isWorking = false
            } catch {
                errorMessage = error.localizedDescription
                isWorking = false
            }
        }
    }
}
