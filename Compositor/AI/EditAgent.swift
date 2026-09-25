import AppKit
import Combine

/// One entry in the agent's step timeline.
nonisolated struct AgentStep: Identifiable, Sendable {
    let id: UUID
    let tool: String
    /// Human-readable summary of the arguments.
    let argumentsSummary: String
    let success: Bool
    let message: String
    let duration: Duration
    let date: Date
}

/// The function-calling loop: the model sees the canvas state and the tool directory,
/// calls tools that edit the document, and receives observations, until it calls
/// `finish` or the step limit is reached.
@MainActor
final class EditAgent: ObservableObject {
    enum Outcome: Equatable {
        case idle, running, finished, failed, stopped
    }

    @Published private(set) var outcome: Outcome = .idle
    @Published private(set) var steps: [AgentStep] = []
    @Published private(set) var summary: String?
    @Published private(set) var errorMessage: String?

    let session: EditorSession
    let transport: any ChatTransport
    let dispatcher: AIToolDispatcher
    var maxSteps = 16

    private var task: Task<Void, Never>?

    static let systemPrompt = """
    You are Compositor Agent, an expert image-editing assistant inside Compositor, a macOS layer-based image editor.
    You edit the open document by calling tools. Plan briefly, then act.

    Coordinates: document pixels with origin (0,0) at the top-left; x grows right and y grows down.
    Layer ids in the canvas state are short 8-character ids; pass them back unchanged.
    Colors accept names ("white", "#FF8800") or red/green/blue values 0-1.

    Rules:
    - Call get_canvas_state first unless the state was just given to you.
    - Make each edit a separate tool call. Each edit is undoable on its own.
    - A failed tool returns an error; read it and try a different approach.
    - Draw onto raster layers; add a blank layer first when one is needed.
    - When the instruction is fully satisfied, call finish with a short summary. Do not ask for confirmation.
    """

    init(session: EditorSession, transport: any ChatTransport, generator: AIToolDispatcher.Generator? = nil) {
        self.session = session
        self.transport = transport
        self.dispatcher = AIToolDispatcher(session: session, transport: transport, generator: generator)
    }

    var isRunning: Bool { outcome == .running }

    func run(_ instruction: String) {
        guard !isRunning else { return }
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        steps = []
        summary = nil
        errorMessage = nil
        outcome = .running
        task = Task { @MainActor [weak self] in
            await self?.execute(trimmed)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func execute(_ instruction: String) async {
        var messages = [
            ChatMessage(role: .system, text: Self.systemPrompt),
            ChatMessage(role: .user, text: instruction),
        ]
        session.isProjectBusy = true
        defer { session.isProjectBusy = false }
        do {
            var finishedSummary: String?
            for _ in 0..<maxSteps {
                try Task.checkCancellation()
                // Fresh state every turn so the model sees the results of its edits.
                let snapshot = CanvasStateSnapshot.capture(session)
                messages.append(ChatMessage(role: .system, text: "Current canvas state:\n\(snapshot.promptText)"))
                let request = ChatRequest(messages: messages, tools: AIToolCatalog.all, temperature: 0.2, timeout: 120)
                let response = try await transport.send(request)
                messages.append(ChatMessage(role: .assistant, text: response.text, toolCalls: response.toolCalls))

                guard let calls = response.toolCalls as [ChatToolCall]?, !calls.isEmpty else {
                    // The model answered in prose without tools: treat it as the final answer.
                    finishedSummary = (response.text?.isEmpty == false ? response.text : nil) ?? "Done."
                    break
                }

                var shouldFinish = false
                for call in calls {
                    if call.name == "finish" {
                        finishedSummary = call.arguments["summary"]?.string ?? "Done."
                        messages.append(ChatMessage(role: .tool, text: "finished", toolCallID: call.id))
                        shouldFinish = true
                        continue
                    }
                    let started = Date()
                    let observation = await dispatcher.dispatch(name: call.name, arguments: call.arguments)
                    let step = AgentStep(
                        id: UUID(),
                        tool: call.name,
                        argumentsSummary: summarizeArguments(call.arguments),
                        success: observation.success,
                        message: observation.message,
                        duration: .seconds(started.timeIntervalSinceNow.magnitude),
                        date: started)
                    steps.append(step)
                    messages.append(ChatMessage(role: .tool, text: observation.message, toolCallID: call.id))
                }
                if shouldFinish { break }
            }
            summary = finishedSummary ?? "Reached the step limit; the work so far is complete and each step is undoable."
            outcome = .finished
        } catch is CancellationError {
            outcome = .stopped
        } catch let error as AIError where error == .cancelled {
            outcome = .stopped
        } catch let error as LocalizedError {
            errorMessage = error.errorDescription ?? "The agent failed."
            outcome = .failed
        } catch {
            errorMessage = "\(error)"
            outcome = .failed
        }
    }

    /// A one-line preview of a tool's arguments for the timeline.
    private func summarizeArguments(_ arguments: JSONValue) -> String {
        guard let object = arguments.object, !object.isEmpty else { return "—" }
        let parts = object.map { key, value -> String in
            switch value {
            case .string(let text): return "\(key): \"\(String(text.prefix(40)))\""
            case .array(let items): return "\(key): [\(items.count) items]"
            default: return "\(key): \(value)"
            }
        }
        return String(parts.joined(separator: ", ").prefix(120))
    }
}
