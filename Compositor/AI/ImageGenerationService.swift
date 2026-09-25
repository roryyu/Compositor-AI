import AppKit
import Foundation

/// One text-to-image request, in document pixels. Adapters snap `width`/`height` to
/// whatever sizes their service accepts.
nonisolated struct ImageGenRequest: Sendable {
    var prompt: String
    var width: Int
    var height: Int
    var count: Int
}

/// Turns a prompt into image bytes. Each provider's quirks stay inside its adapter.
nonisolated protocol ImageGenAdapter: Sendable {
    func generate(_ request: ImageGenRequest) async throws -> [Data]
}

/// The adapter for a preset, or `nil` when the preset has no text-to-image support.
nonisolated enum ImageGenAdapterFactory {
    static func make(preset: ProviderPreset, baseURL: String, model: String, apiKey: String?) -> ImageGenAdapter? {
        switch preset {
        case .openai, .custom:
            OpenAIImagesAdapter(baseURL: baseURL, model: model, apiKey: apiKey)
        case .ark:
            ArkSeedreamAdapter(baseURL: baseURL, model: model, apiKey: apiKey)
        case .dashscope:
            DashScopeWanxAdapter(baseURL: baseURL, model: model, apiKey: apiKey)
        case .gemini:
            GeminiImageAdapter(baseURL: baseURL, model: model, apiKey: apiKey)
        case .deepseek, .zhipu, .moonshot, .ollama:
            nil
        }
    }
}

/// Snaps a requested document-pixel size to the sizes each image service accepts.
nonisolated enum ImageSizeSupport {
    private static func best(_ candidates: [String], width: Int, height: Int) -> String {
        var best = candidates.first ?? "1024x1024"
        var bestScore = Double.greatestFiniteMagnitude
        for candidate in candidates {
            let parts = candidate.split(separator: "x")
            guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) else { continue }
            let aspect = abs(log2((Double(width) / Double(height)) / (w / h)))
            let area = abs(log2((Double(width) * Double(height)) / (w * h)))
            let score = aspect * 2 + area
            if score < bestScore { bestScore = score; best = candidate }
        }
        return best
    }

    /// The nearest OpenAI image size (DALL-E 3 / gpt-image-1 families).
    static func openAI(width: Int, height: Int) -> String {
        best(["1024x1024", "1024x1536", "1536x1024", "1792x1024", "1024x1792", "512x512"], width: width, height: height)
    }

    /// Seedream accepts arbitrary sizes in a range; snap extremes to the closest supported.
    static func ark(width: Int, height: Int) -> String {
        let clamped = (min(max(width, 512), 4096), min(max(height, 512), 4096))
        return "\(clamped.0)x\(clamped.1)"
    }

    /// Wanx uses `W*H` from a fixed menu.
    static func wanx(width: Int, height: Int) -> String {
        best(["1024*1024", "720*1280", "1280*720"], width: width, height: height).replacingOccurrences(of: "x", with: "*")
    }

    /// Gemini image generation takes an aspect ratio.
    static func geminiAspect(width: Int, height: Int) -> String {
        let ratio = Double(width) / Double(height)
        if ratio > 1.2 { return "16:9" }
        if ratio > 0.85 { return "1:1" }
        if ratio > 0.65 { return "4:3" }
        if ratio > 0.45 { return "3:4" }
        return "9:16"
    }
}

/// OpenAI `/images/generations`: gpt-image-1 returns `b64_json`; the DALL-E family may
/// return `url`, which is downloaded.
nonisolated struct OpenAIImagesAdapter: ImageGenAdapter {
    var baseURL: String
    var model: String
    var apiKey: String?
    var urlSession: URLSession = .shared

    func generate(_ request: ImageGenRequest) async throws -> [Data] {
        var url = baseURL.trimmingCharacters(in: .whitespaces)
        while url.hasSuffix("/") { url.removeLast() }
        guard let endpoint = URL(string: url + "/images/generations") else { throw AIError.invalidBaseURL(baseURL) }
        let body = JSONValue.object([
            "model": .string(model),
            "prompt": .string(request.prompt),
            "size": .string(ImageSizeSupport.openAI(width: request.width, height: request.height)),
            "n": .int(request.count),
        ])
        do {
            let data = try await AIAPI.post(url: endpoint, body: body.encodedString, apiKey: apiKey,
                                            timeout: 300, urlSession: urlSession)
            return try await Self.parse(data, apiKey: apiKey, urlSession: urlSession)
        } catch let error as AIError {
            // Gateways such as Alibaba Model Studio MaaS reject this route ("url error") and
            // expose the same image models through chat/completions with image modalities.
            if case .httpStatus(let code, let message, _) = error,
               code == 400, message.localizedLowercase.contains("url error") {
                let fallback = ChatModalitiesImageAdapter(baseURL: url, model: model,
                                                          apiKey: apiKey, urlSession: urlSession)
                return try await fallback.generate(request)
            }
            throw error
        }
    }

    static func parse(_ data: Data, apiKey: String?, urlSession: URLSession = .shared) async throws -> [Data] {
        guard let root = JSONValue.parse(String(decoding: data, as: UTF8.self)) else {
            throw AIError.decodeFailed("the image response is not JSON.")
        }
        if let message = root["error"]?["message"]?.string { throw AIError.invalidResponse(message) }
        guard let items = root["data"]?.array else { throw AIError.decodeFailed("no data array in the image response.") }
        var results: [Data] = []
        for item in items {
            if let base64 = item["b64_json"]?.string, let bytes = Data(base64Encoded: base64) {
                results.append(bytes)
            } else if let urlString = item["url"]?.string, let url = URL(string: urlString) {
                results.append(try await AIAPI.get(url: url, apiKey: nil, timeout: 120, urlSession: urlSession))
            } else {
                throw AIError.decodeFailed("an image item has neither b64_json nor url.")
            }
        }
        guard !results.isEmpty else { throw AIError.decodeFailed("the image response is empty.") }
        return results
    }
}

/// Chat-style image generation: POST chat/completions with image modalities, e.g. Alibaba
/// Model Studio MaaS (qwen-image / wan-image). The assistant message's content carries the
/// image as `{"image": "<url>"}` (Qwen) or `{"image_url": {"url": ...}}` (OpenAI style).
nonisolated struct ChatModalitiesImageAdapter: ImageGenAdapter {
    var baseURL: String
    var model: String
    var apiKey: String?
    var urlSession: URLSession = .shared

    func generate(_ request: ImageGenRequest) async throws -> [Data] {
        var url = baseURL.trimmingCharacters(in: .whitespaces)
        while url.hasSuffix("/") { url.removeLast() }
        guard let endpoint = URL(string: url + "/chat/completions") else { throw AIError.invalidBaseURL(baseURL) }
        let body = JSONValue.object([
            "model": .string(model),
            "messages": .array([
                .object(["role": .string("user"),
                         "content": .array([
                            .object(["type": .string("text"), "text": .string(request.prompt)]),
                         ])]),
            ]),
            "modalities": .array([.string("text"), .string("image")]),
            "n": .int(request.count),
        ])
        let data = try await AIAPI.post(url: endpoint, body: body.encodedString, apiKey: apiKey,
                                        timeout: 300, urlSession: urlSession)
        return try await Self.parse(data, apiKey: apiKey, urlSession: urlSession)
    }

    static func parse(_ data: Data, apiKey: String?, urlSession: URLSession = .shared) async throws -> [Data] {
        guard let root = JSONValue.parse(String(decoding: data, as: UTF8.self)) else {
            throw AIError.decodeFailed("the image response is not JSON.")
        }
        if let message = root["error"]?["message"]?.string { throw AIError.invalidResponse(message) }
        // Accept both the Model Studio native envelope (output.choices) and OpenAI's (choices).
        guard let choices = root["output"]?["choices"]?.array ?? root["choices"]?.array else {
            throw AIError.decodeFailed("no choices in the image response.")
        }
        var results: [Data] = []
        for choice in choices {
            let parts = choice["message"]?["content"]?.array ?? []
            for part in parts {
                guard let reference = part["image"]?.string ?? part["image_url"]?["url"]?.string else { continue }
                results.append(try await download(reference, urlSession: urlSession))
            }
        }
        guard !results.isEmpty else { throw AIError.decodeFailed("the image response contained no image.") }
        return results
    }

    private static func download(_ reference: String, urlSession: URLSession) async throws -> Data {
        if reference.hasPrefix("data:") {
            guard let comma = reference.firstIndex(of: ",") else {
                throw AIError.decodeFailed("a data URI image could not be read.")
            }
            let encoded = reference[reference.index(after: comma)...]
            guard let bytes = Data(base64Encoded: String(encoded)) else {
                throw AIError.decodeFailed("a data URI image could not be decoded.")
            }
            return bytes
        }
        guard let url = URL(string: reference) else { throw AIError.decodeFailed("an image URL is not valid.") }
        // The returned URLs are short-lived signed OSS links; no API key needed.
        return try await AIAPI.get(url: url, apiKey: nil, timeout: 120, urlSession: urlSession)
    }
}

/// Volcengine Ark `/api/v3/images/generations` (Seedream / Doubao image models).
nonisolated struct ArkSeedreamAdapter: ImageGenAdapter {
    var baseURL: String
    var model: String
    var apiKey: String?
    var urlSession: URLSession = .shared

    func generate(_ request: ImageGenRequest) async throws -> [Data] {
        var url = baseURL.trimmingCharacters(in: .whitespaces)
        while url.hasSuffix("/") { url.removeLast() }
        guard let endpoint = URL(string: url + "/images/generations") else { throw AIError.invalidBaseURL(baseURL) }
        let body = JSONValue.object([
            "model": .string(model),
            "prompt": .string(request.prompt),
            "size": .string(ImageSizeSupport.ark(width: request.width, height: request.height)),
            "response_format": .string("b64_json"),
        ])
        let data = try await AIAPI.post(url: endpoint, body: body.encodedString, apiKey: apiKey,
                                        timeout: 300, urlSession: urlSession)
        // The shared parser also accepts `url` items, in case the model ignores the format.
        return try await OpenAIImagesAdapter.parse(data, apiKey: apiKey, urlSession: urlSession)
    }
}

/// DashScope Wanx text-to-image: submit an async task, poll until it finishes, download.
nonisolated struct DashScopeWanxAdapter: ImageGenAdapter {
    var baseURL: String
    var model: String
    var apiKey: String?
    var urlSession: URLSession = .shared
    /// Seconds to keep polling a task before giving up.
    var pollTimeout: TimeInterval = 300

    /// The native API root: a compatible-mode base URL is translated.
    var nativeBaseURL: String {
        var url = baseURL.trimmingCharacters(in: .whitespaces)
        while url.hasSuffix("/") { url.removeLast() }
        if url.contains("/compatible-mode/v1") { url = url.replacingOccurrences(of: "/compatible-mode/v1", with: "/api/v1") }
        return url
    }

    func generate(_ request: ImageGenRequest) async throws -> [Data] {
        guard let submitURL = URL(string: nativeBaseURL + "/services/aigc/text2image/image-synthesis") else {
            throw AIError.invalidBaseURL(baseURL)
        }
        let body = JSONValue.object([
            "model": .string(model),
            "input": .object(["prompt": .string(request.prompt)]),
            "parameters": .object([
                "size": .string(ImageSizeSupport.wanx(width: request.width, height: request.height)),
                "n": .int(request.count),
            ]),
        ])
        let submitted = try await AIAPI.post(url: submitURL, body: body.encodedString, apiKey: apiKey, timeout: 60,
                                             urlSession: urlSession,
                                             extraHeaders: ["X-DashScope-Async": "enable"])
        guard let root = JSONValue.parse(String(decoding: submitted, as: UTF8.self)),
              let taskID = root["output"]?["task_id"]?.string else {
            throw AIError.decodeFailed("DashScope did not return a task id.")
        }
        let deadline = Date().addingTimeInterval(pollTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(2))
            guard let pollURL = URL(string: "\(nativeBaseURL)/tasks/\(taskID)") else {
                throw AIError.invalidBaseURL(nativeBaseURL)
            }
            let pollData = try await AIAPI.get(url: pollURL, apiKey: apiKey, timeout: 60, urlSession: urlSession)
            guard let poll = JSONValue.parse(String(decoding: pollData, as: UTF8.self)),
                  let output = poll["output"] else { continue }
            switch output["task_status"]?.string ?? "PENDING" {
            case "SUCCEEDED":
                var results: [Data] = []
                for item in output["results"]?.array ?? [] {
                    guard let urlString = item["url"]?.string, let url = URL(string: urlString) else { continue }
                    results.append(try await AIAPI.get(url: url, apiKey: nil, timeout: 120, urlSession: urlSession))
                }
                guard !results.isEmpty else { throw AIError.decodeFailed("the finished task has no images.") }
                return results
            case "FAILED", "CANCELED", "UNKNOWN":
                let reason = output["message"]?.string ?? poll["message"]?.string ?? "the task failed."
                throw AIError.imageFailed(reason)
            default: continue // PENDING / RUNNING
            }
        }
        throw AIError.timeout
    }
}

/// Gemini `generateContent` with image output; one call per requested image.
nonisolated struct GeminiImageAdapter: ImageGenAdapter {
    var baseURL: String
    var model: String
    var apiKey: String?
    var urlSession: URLSession = .shared

    /// The native v1beta root; the preset's OpenAI-compatibility suffix is removed.
    var nativeBaseURL: String {
        var url = baseURL.trimmingCharacters(in: .whitespaces)
        while url.hasSuffix("/") { url.removeLast() }
        if url.hasSuffix("/openai") { url.removeLast("/openai".count) }
        return url
    }

    func generate(_ request: ImageGenRequest) async throws -> [Data] {
        let base = nativeBaseURL
        guard let endpoint = URL(string: "\(base)/models/\(model):generateContent") else {
            throw AIError.invalidBaseURL(baseURL)
        }
        let body = JSONValue.object([
            "contents": .array([.object(["parts": .array([.object(["text": .string(request.prompt)])])])]),
            "generationConfig": .object([
                "responseModalities": .array([.string("TEXT"), .string("IMAGE")]),
                "imageConfig": .object(["aspectRatio": .string(ImageSizeSupport.geminiAspect(width: request.width, height: request.height))]),
            ]),
        ])
        var results: [Data] = []
        for _ in 0..<max(1, request.count) {
            let data = try await AIAPI.post(url: endpoint, body: body.encodedString, apiKey: apiKey, timeout: 300,
                                            urlSession: urlSession,
                                            extraHeaders: ["x-goog-api-key": apiKey ?? ""])
            results.append(try Self.parseOne(data))
        }
        return results
    }

    static func parseOne(_ data: Data) throws -> Data {
        guard let root = JSONValue.parse(String(decoding: data, as: UTF8.self)) else {
            throw AIError.decodeFailed("the Gemini response is not JSON.")
        }
        if let message = root["error"]?["message"]?.string { throw AIError.invalidResponse(message) }
        for part in root["candidates"]?[0]?["content"]?["parts"]?.array ?? [] {
            if let base64 = part["inlineData"]?["data"]?.string, let bytes = Data(base64Encoded: base64) {
                return bytes
            }
        }
        let reason = root["candidates"]?[0]?["finishReason"]?.string ?? "no image in the response."
        throw AIError.decodeFailed("Gemini returned no image (\(reason)).")
    }
}

/// Facade over the configured image provider: prompt in, decoded bitmaps out.
nonisolated struct ImageGenerationService: Sendable {
    var adapter: any ImageGenAdapter

    func generate(_ request: ImageGenRequest) async throws -> [CGImage] {
        let payloads = try await adapter.generate(request)
        return try payloads.map { try ImageCodec.decode($0) }
    }
}
