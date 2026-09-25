import AppKit

/// Asks a multimodal model about an image: canvas analysis, layer questions, and prompt
/// suggestions all go through one call.
nonisolated struct VisionService: Sendable {
    var transport: ChatTransport

    static let systemPrompt = """
    You are an image analysis assistant inside Compositor, a macOS image editor.
    Answer questions about the image precisely and concisely. When asked for a
    text-to-image prompt, write a vivid, concrete prompt in English.
    """

    func analyze(image: CGImage, question: String) async throws -> String {
        let payload = try ImageCodec.chatJPEGData(image)
        let request = ChatRequest(
            messages: [
                ChatMessage(role: .system, text: Self.systemPrompt),
                ChatMessage(role: .user, parts: [.text(question), .image(data: payload, mime: "image/jpeg")]),
            ],
            temperature: 0.4)
        let response = try await transport.send(request)
        guard let text = response.text, !text.isEmpty else {
            throw AIError.invalidResponse("the model returned no text.")
        }
        return text
    }

    /// A one-word reply used by "Test Connection" in settings.
    func testConnection() async throws {
        let request = ChatRequest(messages: [ChatMessage(role: .user, text: "Reply with the single word: ok")], temperature: 0)
        let response = try await transport.send(request)
        guard response.text != nil || !response.toolCalls.isEmpty else {
            throw AIError.invalidResponse("the model returned no content.")
        }
    }
}
