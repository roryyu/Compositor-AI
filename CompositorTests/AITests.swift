import AppKit
import Testing
@testable import Compositor

// MARK: - Keychain

@MainActor
struct AIKeychainTests {
    @Test func inMemoryStoreRoundTrips() throws {
        let store = InMemoryKeychainStore()
        #expect(try store.read(account: "x") == nil)
        try store.write("secret", account: "x")
        #expect(try store.read(account: "x") == "secret")
        try store.write(nil, account: "x")
        #expect(try store.read(account: "x") == nil)
    }

    @Test func settingsPersistAcrossReload() throws {
        let suite = "ai-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let keychain = InMemoryKeychainStore()
        let store = AISettingsStore(defaults: defaults, keychain: keychain)

        store.choosePreset(.ark, for: .vision)
        store.update(.vision) { $0.model = "test-model" }
        store.setAPIKey(.vision, "key-123")
        #expect(store.vision.preset == .ark)
        #expect(store.vision.baseURL.contains("ark"))
        #expect(store.isConfigured(.vision))

        let reloaded = AISettingsStore(defaults: defaults, keychain: keychain)
        #expect(reloaded.vision.preset == .ark)
        #expect(reloaded.vision.model == "test-model")
        #expect(reloaded.apiKey(.vision) == "key-123")
    }
}

// MARK: - Transport encoding and decoding

struct AITransportTests {
    @Test func parsesToolCallResponse() throws {
        let body = """
        {"choices":[{"finish_reason":"tool_calls","message":{"content":null,
        "tool_calls":[{"id":"call1","type":"function",
        "function":{"name":"add_blank_layer","arguments":"{}"}}]}}]}
        """
        let response = try OpenAICompatTransport.parseResponse(Data(body.utf8))
        #expect(response.finishReason == "tool_calls")
        #expect(response.toolCalls.first?.id == "call1")
        #expect(response.toolCalls.first?.name == "add_blank_layer")
        #expect(response.toolCalls.first?.arguments == .emptyObject)
        #expect(response.text == nil)
    }

    @Test func parsesProseAndArrayContent() throws {
        let body = """
        {"choices":[{"finish_reason":"stop","message":{"content":"all done"}}]}
        """
        let response = try OpenAICompatTransport.parseResponse(Data(body.utf8))
        #expect(response.text == "all done")
        #expect(response.toolCalls.isEmpty)
    }

    @Test func wireMessageEncodesMultimodalParts() {
        let message = ChatMessage(role: .user, parts: [
            .text("look"),
            .image(data: Data([1, 2, 3]), mime: "image/jpeg"),
        ])
        let wire = OpenAICompatTransport.wireMessage(message)
        #expect(wire["role"]?.string == "user")
        let parts = wire["content"]?.array
        #expect(parts?[0]["text"]?.string == "look")
        let url = parts?[1]["image_url"]?["url"]?.string
        #expect(url?.hasPrefix("data:image/jpeg;base64,") == true)
    }

    @Test func wireMessageEncodesToolCallsAndToolAnswers() {
        let assistant = ChatMessage(role: .assistant, toolCalls: [
            ChatToolCall(id: "c1", name: "undo", arguments: .emptyObject),
        ])
        let wire = OpenAICompatTransport.wireMessage(assistant)
        #expect(wire["tool_calls"]?[0]?["function"]?["name"]?.string == "undo")
        let answer = ChatMessage(role: .tool, text: "ok", toolCallID: "c1")
        let answerWire = OpenAICompatTransport.wireMessage(answer)
        #expect(answerWire["tool_call_id"]?.string == "c1")
        #expect(answerWire["content"]?.string == "ok")
    }
}

// MARK: - Adapter response decoding

struct AIAdapterDecodingTests {
    @Test func openAIB64ItemDecodes() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let body = JSONValue.object([
            "data": .array([.object(["b64_json": .string(png.base64EncodedString())])]),
        ]).encodedString
        let results = try await OpenAIImagesAdapter.parse(Data(body.utf8), apiKey: nil)
        #expect(results == [png])
    }

    @Test func openAIErrorItemThrows() async {
        let body = #"{"error":{"message":"bad key"}}"#
        await #expect(throws: AIError.self) {
            try await OpenAIImagesAdapter.parse(Data(body.utf8), apiKey: nil)
        }
    }

    @Test func geminiInlineDataDecodes() throws {
        let bytes = Data([1, 2, 3, 4])
        let body = """
        {"candidates":[{"content":{"parts":[
        {"inlineData":{"data":"\(bytes.base64EncodedString())"}}
        ]}}]}
        """
        let result = try GeminiImageAdapter.parseOne(Data(body.utf8))
        #expect(result == bytes)
    }

    @Test func chatModalitiesResponseExtractsImageURL() async throws {
        let body = """
        {"output":{"choices":[{"message":{"role":"assistant","content":[
        {"image":"https://example.test/pic.png?sig=abc"}
        ]}}]}
        """
        // Parsing without downloading: a bad host must surface as a network error after extraction,
        // proving the URL was read from the Qwen-style content.
        await #expect(throws: AIError.self) {
            try await ChatModalitiesImageAdapter.parse(Data(body.utf8), apiKey: nil)
        }
    }

    @Test func chatModalitiesDataURIDecodes() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let body = """
        {"choices":[{"message":{"content":[
        {"image_url":{"url":"data:image/png;base64,\(png.base64EncodedString())"}}
        ]}}]}
        """
        let results = try await ChatModalitiesImageAdapter.parse(Data(body.utf8), apiKey: nil)
        #expect(results == [png])
    }
}

// MARK: - Canvas snapshot

@MainActor
struct AISnapshotTests {
    @Test func capturesLayerTree() {
        let session = EditorSession()
        session.createDocument(width: 800, height: 600)
        session.addBlankLayer()
        let snapshot = CanvasStateSnapshot.capture(session)
        #expect(snapshot.width == 800)
        #expect(snapshot.height == 600)
        #expect(snapshot.layers.count == 1)
        #expect(snapshot.activeLayerID == snapshot.layers.first?.shortID)
        #expect(snapshot.promptText.contains("Layer 1"))
        #expect(snapshot.promptText.contains("800x600"))
    }
}

// MARK: - Tool dispatcher

@MainActor
struct AIToolDispatcherTests {
    private func makeSession() -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 800, height: 600)
        return session
    }

    @Test func blankLayerThenUndo() async {
        let session = makeSession()
        let dispatcher = AIToolDispatcher(session: session)

        let observation = await dispatcher.dispatch(name: "add_blank_layer", arguments: .emptyObject)
        #expect(observation.success)
        session.isProjectBusy = false
        #expect(session.document?.layers.count == 1)
        #expect(session.canUndo)

        let undoObservation = await dispatcher.dispatch(name: "undo", arguments: .emptyObject)
        #expect(undoObservation.success)
        session.isProjectBusy = false
        #expect(session.document?.layers.isEmpty == true)
    }

    @Test func setsLayerProperties() async throws {
        let session = makeSession()
        session.addBlankLayer()
        let dispatcher = AIToolDispatcher(session: session)
        let args = try #require(JSONValue.parse("""
        {"opacity":0.5,"visible":false,"blend_mode":"Multiply","name":"Custom"}
        """))
        let observation = await dispatcher.dispatch(name: "set_layer_properties", arguments: args)
        #expect(observation.success)
        session.isProjectBusy = false
        let layer = try #require(session.activeLayer)
        #expect(layer.opacity == 0.5)
        #expect(layer.isVisible == false)
        #expect(layer.blendMode == .multiply)
        #expect(layer.name == "Custom")
    }

    @Test func drawsShapeLayer() async throws {
        let session = makeSession()
        let dispatcher = AIToolDispatcher(session: session)
        let args = try #require(JSONValue.parse("""
        {"kind":"Ellipse","rect":[50,60,200,120],"color":"#FF0000"}
        """))
        let observation = await dispatcher.dispatch(name: "draw_shape", arguments: args)
        #expect(observation.success)
        session.isProjectBusy = false
        let layer = try #require(session.document?.layers.first)
        #expect(layer.name == "Ellipse 1")
        #expect(layer.origin == CGPoint(x: 50, y: 60))
        #expect(layer.size == CGSize(width: 200, height: 120))
        #expect(layer.liveShape != nil)
    }

    @Test func transformsLayerPosition() async throws {
        let session = makeSession()
        session.addBlankLayer()
        let dispatcher = AIToolDispatcher(session: session)
        let args = try #require(JSONValue.parse(#"{"dx":10,"dy":-5}"#))
        let observation = await dispatcher.dispatch(name: "transform_layer", arguments: args)
        #expect(observation.success)
        session.isProjectBusy = false
        #expect(session.activeLayer?.origin == CGPoint(x: 10, y: -5))
    }

    @Test func selectionLifecycle() async throws {
        let session = makeSession()
        let dispatcher = AIToolDispatcher(session: session)

        let setArgs = try #require(JSONValue.parse(#"{"shape":"rect","rect":[10,10,100,100]}"#))
        let set = await dispatcher.dispatch(name: "set_selection", arguments: setArgs)
        #expect(set.success)
        session.isProjectBusy = false
        let bounds = try #require(session.selection?.path.boundingBoxOfPath)
        #expect(bounds.width == 100)

        let invertArgs = try #require(JSONValue.parse(#"{"action":"invert"}"#))
        let invert = await dispatcher.dispatch(name: "modify_selection", arguments: invertArgs)
        #expect(invert.success)
        session.isProjectBusy = false
        #expect(session.selection != nil)

        let clearArgs = try #require(JSONValue.parse(#"{"action":"deselect"}"#))
        let clear = await dispatcher.dispatch(name: "modify_selection", arguments: clearArgs)
        #expect(clear.success)
        session.isProjectBusy = false
        #expect(session.selection == nil)
    }

    @Test func duplicateAndDeleteLayer() async throws {
        let session = makeSession()
        session.addBlankLayer()
        let dispatcher = AIToolDispatcher(session: session)
        let shortID = CanvasStateSnapshot.shortID(try #require(session.activeLayerID))

        let duplicate = await dispatcher.dispatch(
            name: "duplicate_layer",
            arguments: try #require(JSONValue.parse(#"{"layer_id":"\#(shortID)"}"#)))
        #expect(duplicate.success)
        session.isProjectBusy = false
        #expect(session.document?.layers.count == 2)

        let delete = await dispatcher.dispatch(
            name: "delete_layer",
            arguments: try #require(JSONValue.parse(#"{"layer_id":"\#(shortID)"}"#)))
        #expect(delete.success)
        session.isProjectBusy = false
        #expect(session.document?.layers.count == 1)
    }

    @Test func canvasStateAndUnknownTools() async {
        let session = makeSession()
        let dispatcher = AIToolDispatcher(session: session)

        let state = await dispatcher.dispatch(name: "get_canvas_state", arguments: .emptyObject)
        #expect(state.success)
        #expect(JSONValue.parse(state.message)?["width"]?.double == 800)

        let unknown = await dispatcher.dispatch(name: "does_not_exist", arguments: .emptyObject)
        #expect(!unknown.success)
    }

    @Test func missingImageGeneratorIsObservedFailure() async {
        let session = makeSession()
        let dispatcher = AIToolDispatcher(session: session)
        let observation = await dispatcher.dispatch(
            name: "generate_image",
            arguments: JSONValue.parse(#"{"prompt":"a cat"}"#) ?? .emptyObject)
        #expect(!observation.success)
    }
}
