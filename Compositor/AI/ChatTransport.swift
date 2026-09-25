import Foundation

/// A JSON value of any shape, so provider responses and tool arguments can be decoded
/// without hand-writing a schema for every field.
nonisolated indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(any: Any) {
        switch any {
        case is NSNull: self = .null
        case let number as NSNumber:
            if number.isBoolean { self = .bool(number.boolValue) }
            else if ["f", "d"].contains(String(cString: number.objCType)) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map { JSONValue(any: $0) })
        case let dict as [String: Any]:
            self = .object(dict.reduce(into: [:]) { $0[$1.key] = JSONValue(any: $1.value) })
        default: self = .string(String(describing: any))
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var string: String? { if case .string(let value) = self { return value }; return nil }
    var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    var double: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }
    var array: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
    var object: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
    subscript(key: String) -> JSONValue? { object?[key] }
    subscript(index: Int) -> JSONValue? { array?[index] }

    /// The JSON text of this value.
    var encodedString: String {
        guard let data = try? JSONEncoder().encode(self) else { return "null" }
        return String(data: data, encoding: .utf8) ?? "null"
    }

    /// Decodes JSON text; nil when it is not valid JSON.
    static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return value
    }

    /// An empty object, for tool calls without arguments.
    static let emptyObject = JSONValue.object([:])

    /// Builds a JSON Schema `{"type":"object","properties":{...},"required":[...]}`.
    static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array(required.map { .string($0) }),
                 "additionalProperties": .bool(false)])
    }
    static func stringProperty(_ description: String, enum values: [String]? = nil) -> JSONValue {
        var result: [String: JSONValue] = ["type": .string("string"), "description": .string(description)]
        if let values { result["enum"] = .array(values.map { .string($0) }) }
        return .object(result)
    }
    static func numberProperty(_ description: String, minimum: Double? = nil, maximum: Double? = nil) -> JSONValue {
        var result: [String: JSONValue] = ["type": .string("number"), "description": .string(description)]
        if let minimum { result["minimum"] = .double(minimum) }
        if let maximum { result["maximum"] = .double(maximum) }
        return .object(result)
    }
    static func integerProperty(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> JSONValue {
        var result: [String: JSONValue] = ["type": .string("integer"), "description": .string(description)]
        if let minimum { result["minimum"] = .int(minimum) }
        if let maximum { result["maximum"] = .int(maximum) }
        return .object(result)
    }
    static func boolProperty(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }
}

extension NSNumber {
    var isBoolean: Bool { CFGetTypeID(self) == CFBooleanGetTypeID() }
}

/// One piece of a multimodal chat message.
nonisolated enum ChatPart: Sendable {
    case text(String)
    case image(data: Data, mime: String)
}

/// A tool call the model asked for, with its arguments already parsed.
nonisolated struct ChatToolCall: Equatable, Sendable {
    var id: String
    var name: String
    var arguments: JSONValue
}

/// A tool advertised to the model: name, description, and a JSON Schema `parameters`.
nonisolated struct ToolDefinition: Sendable {
    var name: String
    var description: String
    var parameters: JSONValue
}

nonisolated struct ChatMessage: Sendable {
    enum Role: String, Sendable { case system, user, assistant, tool }
    var role: Role
    /// Plain text content, for system, assistant, and tool messages.
    var text: String?
    /// Multimodal user content; when set it replaces `text` on the wire.
    var parts: [ChatPart]?
    var toolCalls: [ChatToolCall]?
    /// The call this message answers, for role `.tool`.
    var toolCallID: String?

    init(role: Role, text: String? = nil, parts: [ChatPart]? = nil, toolCalls: [ChatToolCall]? = nil, toolCallID: String? = nil) {
        self.role = role
        self.text = text
        self.parts = parts
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }
}

nonisolated struct ChatRequest: Sendable {
    var messages: [ChatMessage]
    var tools: [ToolDefinition]?
    var temperature: Double?
    /// Per-request network timeout, seconds.
    var timeout: TimeInterval = 120

    init(messages: [ChatMessage], tools: [ToolDefinition]? = nil, temperature: Double? = nil, timeout: TimeInterval = 120) {
        self.messages = messages
        self.tools = tools
        self.temperature = temperature
        self.timeout = timeout
    }
}

nonisolated struct ChatResponse: Sendable {
    /// The model's text, when it said something.
    var text: String?
    var toolCalls: [ChatToolCall]
    var finishReason: String?
}

/// Sends one chat request and returns the model's answer.
nonisolated protocol ChatTransport: Sendable {
    func send(_ request: ChatRequest) async throws -> ChatResponse
}

/// OpenAI-compatible `/chat/completions`, including the `tools` parameter. Covers
/// OpenAI, DeepSeek, Qwen compatible-mode, Zhipu, Moonshot, Ark, Gemini's OpenAI
/// compatibility layer, and Ollama.
nonisolated struct OpenAICompatTransport: ChatTransport {
    var baseURL: String
    var model: String
    var apiKey: String?
    var urlSession: URLSession = .shared
    /// Retries for 429 and 5xx with exponential backoff.
    var maxRetries = 2

    func send(_ request: ChatRequest) async throws -> ChatResponse {
        var url = baseURL.trimmingCharacters(in: .whitespaces)
        while url.hasSuffix("/") { url.removeLast() }
        guard let endpoint = URL(string: url + "/chat/completions") else {
            throw AIError.invalidBaseURL(baseURL)
        }
        var body: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(request.messages.map(Self.wireMessage)),
            "stream": .bool(false),
        ]
        if let temperature = request.temperature { body["temperature"] = .double(temperature) }
        if let tools = request.tools, !tools.isEmpty {
            body["tools"] = .array(tools.map { tool in
                .object(["type": .string("function"),
                         "function": .object(["name": .string(tool.name),
                                              "description": .string(tool.description),
                                              "parameters": tool.parameters])])
            })
            body["tool_choice"] = .string("auto")
        }
        let payload = JSONValue.object(body).encodedString
        var attempt = 0
        while true {
            let data = try await AIAPI.post(url: endpoint, body: payload, apiKey: apiKey,
                                            timeout: request.timeout, urlSession: urlSession)
            do { return try Self.parseResponse(data) }
            catch let error as AIError {
                guard error.isRetryable, attempt < maxRetries else { throw error }
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                attempt += 1
            }
        }
    }

    /// The OpenAI wire format for one message.
    static func wireMessage(_ message: ChatMessage) -> JSONValue {
        var result: [String: JSONValue] = ["role": .string(message.role.rawValue)]
        if let parts = message.parts {
            let content = parts.map { part -> JSONValue in
                switch part {
                case .text(let text):
                    .object(["type": .string("text"), "text": .string(text)])
                case .image(let data, let mime):
                    .object(["type": .string("image_url"),
                             "image_url": .object(["url": .string(ImageCodec.dataURI(data, mime: mime))])])
                }
            }
            result["content"] = .array(content)
        } else {
            result["content"] = .string(message.text ?? "")
        }
        if let toolCalls = message.toolCalls {
            result["tool_calls"] = .array(toolCalls.map { call in
                .object(["id": .string(call.id), "type": .string("function"),
                         "function": .object(["name": .string(call.name),
                                              "arguments": .string(call.arguments.encodedString)])])
            })
        }
        if let toolCallID = message.toolCallID { result["tool_call_id"] = .string(toolCallID) }
        return .object(result)
    }

    /// Parses a `/chat/completions` response body.
    static func parseResponse(_ data: Data) throws -> ChatResponse {
        guard let root = JSONValue.parse(String(decoding: data, as: UTF8.self)) else {
            throw AIError.decodeFailed("the body is not JSON.")
        }
        if let message = root["error"]?["message"]?.string {
            throw AIError.invalidResponse(message)
        }
        guard let choice = root["choices"]?[0] else { throw AIError.decodeFailed("no choices in the response.") }
        let rawMessage = choice["message"] ?? JSONValue.object([:])
        var text: String?
        switch rawMessage["content"] {
        case .string(let value): text = value
        case .array(let parts):
            let joined = parts.compactMap { $0["text"]?.string }.joined(separator: "\n")
            text = joined.isEmpty ? nil : joined
        default: break
        }
        if text?.isEmpty == true { text = nil }
        var calls: [ChatToolCall] = []
        for (index, call) in (rawMessage["tool_calls"]?.array ?? []).enumerated() {
            let function = call["function"] ?? JSONValue.object([:])
            let raw = function["arguments"]?.string ?? "{}"
            let arguments = JSONValue.parse(raw) ?? .emptyObject
            calls.append(ChatToolCall(id: call["id"]?.string ?? "call_\(index)",
                                      name: function["name"]?.string ?? "",
                                      arguments: arguments))
        }
        return ChatResponse(text: text, toolCalls: calls, finishReason: choice["finish_reason"]?.string)
    }
}

/// Shared HTTP plumbing for chat and image endpoints: POST/GET with bearer auth,
/// status mapping to `AIError`, and retry with backoff on 429/5xx.
nonisolated enum AIAPI {
    static func post(url: URL, body: String, apiKey: String?, timeout: TimeInterval,
                     urlSession: URLSession = .shared, extraHeaders: [String: String] = [:],
                     retries: Int = 2) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = Data(body.utf8)
        return try await run(request, urlSession: urlSession, retries: retries)
    }

    static func get(url: URL, apiKey: String?, timeout: TimeInterval,
                    urlSession: URLSession = .shared, extraHeaders: [String: String] = [:],
                    retries: Int = 2) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        return try await run(request, urlSession: urlSession, retries: retries)
    }

    static func run(_ request: URLRequest, urlSession: URLSession, retries: Int) async throws -> Data {
        var attempt = 0
        while true {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await urlSession.data(for: request)
            } catch let error as URLError {
                if error.code == .cancelled { throw AIError.cancelled }
                if attempt < retries {
                    attempt += 1
                    try await Task.sleep(for: .seconds(pow(2, Double(attempt - 1))))
                    continue
                }
                throw AIError.network(error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse("no HTTP status.") }
            guard (200...299).contains(http.statusCode) else {
                let message = String(data: data, encoding: .utf8) ?? ""
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                let error = AIError.httpStatus(code: http.statusCode, message: message, retryAfter: retryAfter)
                guard error.isRetryable, attempt < retries else { throw error }
                let delay = retryAfter ?? pow(2, Double(attempt))
                attempt += 1
                try await Task.sleep(for: .seconds(delay))
                continue
            }
            return data
        }
    }
}
