import AppKit
import Foundation
import Network

/// A minimal local-only HTTP control surface for external agents (the Compositor MCP
/// bridge, shell scripts). It listens on 127.0.0.1 on an ephemeral port, requires a
/// bearer token, and exposes the same tool directory the in-app agent uses:
///
/// - GET  /v1/health — service status
/// - GET  /v1/tools  — the tool directory as MCP-shaped JSON
/// - GET  /v1/state  — current canvas snapshot
/// - POST /v1/call   — {"name": ..., "arguments": {...}} runs one tool
///
/// The endpoint (port + token) is published to a JSON file so a separate, unsandboxed
/// helper can find it. The loopback bind, random port and per-launch token keep the
/// surface local-only.
@MainActor
final class LocalControlServer {
    /// Published endpoint description, read by the MCP bridge.
    nonisolated struct EndpointFile: Codable {
        var scheme: String
        var host: String
        var port: Int
        var token: String
    }

    private let workspace: ProjectWorkspace
    private var listener: NWListener?
    /// Active connections, kept alive until they finish.
    private var connections: [ObjectIdentifier: LocalHTTPConnection] = [:]
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private(set) var port: Int = 0
    let token: String

    /// Directory the endpoint file is written to (inside the sandbox container when sandboxed).
    private var publishDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.folderName, isDirectory: true)
    }
    private var publishFile: URL { publishDirectory.appendingPathComponent(Self.fileName) }

    static let folderName = "Compositor"
    static let fileName = "control.json"
    /// Bundle id used by the bridge to look up the container-side file.
    static let bundleID = "com.wonderassembly.compositor"

    init(workspace: ProjectWorkspace) {
        self.workspace = workspace
        self.token = Self.makeToken()
    }

    /// Starts listening; resumes once the endpoint file has been published.
    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(IPv4Address("127.0.0.1")!), port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else {
                        self.readyContinuation?.resume(throwing: AIError.invalidResponse("no listening port."))
                        self.readyContinuation = nil
                        return
                    }
                    self.port = Int(port)
                    do {
                        try self.publish()
                        self.readyContinuation?.resume()
                        self.readyContinuation = nil
                    } catch {
                        self.readyContinuation?.resume(throwing: error)
                        self.readyContinuation = nil
                    }
                case .failed(let error):
                    self.readyContinuation?.resume(throwing: error)
                    self.readyContinuation = nil
                default: break
                }
            }
        }
        self.listener = listener
        try await withCheckedThrowingContinuation { continuation in
            self.readyContinuation = continuation
            listener.start(queue: .main)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        // The endpoint file is left in place: it is rewritten on every launch and may be
        // shared by concurrently running test servers pointing at their own ports.
    }

    // MARK: Endpoint publishing

    private func publish() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: publishDirectory, withIntermediateDirectories: true)
        let description = EndpointFile(scheme: "http", host: "127.0.0.1", port: port, token: token)
        let data = try JSONEncoder().encode(description)
        try data.write(to: publishFile, options: .atomic)
        var attributes = try fm.attributesOfItem(atPath: publishFile.path)
        attributes[.posixPermissions] = 0o600
        try fm.setAttributes(attributes, ofItemAtPath: publishFile.path)
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let client = LocalHTTPConnection(connection: connection, onFinish: { [weak self] in
            self?.connections.removeValue(forKey: ObjectIdentifier(connection))
        }) { [weak self] request in
            if let self { return await self.route(request) }
            return LocalHTTPResponse(status: 503, json: .object(["error": .string("server is stopping")]))
        }
        connections[ObjectIdentifier(connection)] = client
        client.start()
    }

    private func route(_ request: LocalHTTPRequest) async -> LocalHTTPResponse {
        guard request.headers["authorization"]?.lowercased() == "bearer \(token)" else {
            return LocalHTTPResponse(status: 401,
                                     json: .object(["error": .string("missing or invalid token")]))
        }
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        switch (request.method, path) {
        case ("GET", "/v1/health"):
            return LocalHTTPResponse(json: .object([
                "status": .string("ok"),
                "service": .string("compositor-control"),
                "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"),
            ]))
        case ("GET", "/v1/tools"):
            let tools = JSONValue.array(AIToolCatalog.all.map { tool in
                .object(["name": .string(tool.name),
                         "description": .string(tool.description),
                         "inputSchema": tool.parameters])
            })
            return LocalHTTPResponse(json: tools)
        case ("GET", "/v1/state"):
            return LocalHTTPResponse(json: CanvasStateSnapshot.capture(workspace.current.session).json)
        case ("POST", "/v1/call"):
            return await call(request.body)
        default:
            return LocalHTTPResponse(status: 404, json: .object(["error": .string("not found")]))
        }
    }

    /// Runs one tool against the currently selected tab's session.
    private func call(_ body: Data) async -> LocalHTTPResponse {
        guard let root = JSONValue.parse(String(decoding: body, as: UTF8.self)),
              let name = root["name"]?.string, !name.isEmpty else {
            return LocalHTTPResponse(status: 400, json: .object(["error": .string("a tool name is required")]))
        }
        let arguments = root["arguments"] ?? .emptyObject
        let session = workspace.current.session
        let dispatcher = AIToolDispatcher(session: session,
                                          transport: makeVisionTransport(),
                                          generator: makeImageGenerator())
        // The dispatcher clears the busy flag for the call and restores it to true; we set it
        // around the call so the session's baseline (false) is preserved afterwards.
        session.isProjectBusy = true
        let observation = await dispatcher.dispatch(name: name, arguments: arguments)
        session.isProjectBusy = false
        return LocalHTTPResponse(json: .object([
            "success": .bool(observation.success),
            "message": .string(observation.message),
        ]))
    }

    /// Vision transport for analyze_image; nil when unconfigured (the tool then reports it).
    private func makeVisionTransport() -> (any ChatTransport)? {
        try? AISettingsStore.shared.makeTransport(.vision)
    }

    /// Image generator for generate_image, when an image configuration exists.
    private func makeImageGenerator() -> AIToolDispatcher.Generator? {
        let store = AISettingsStore.shared
        let config = store.image
        let key = store.apiKey(.image)
        guard let base = config.cleanedBaseURL, !key.isEmpty,
              let adapter = ImageGenAdapterFactory.make(preset: config.preset, baseURL: base,
                                                        model: config.model, apiKey: key) else {
            return nil
        }
        let service = ImageGenerationService(adapter: adapter)
        let size = workspace.current.session.document?.size ?? CGSize(width: 1024, height: 1024)
        return { prompt in
            try await service.generate(
                ImageGenRequest(prompt: prompt, width: Int(size.width), height: Int(size.height), count: 1))
        }
    }

    // MARK: Token

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        // Extremely unlikely fallback.
        return UUID().uuidString + UUID().uuidString
    }
}

// MARK: - Minimal HTTP/1.1 request handling

nonisolated struct LocalHTTPRequest: Sendable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
}

nonisolated struct LocalHTTPResponse: Sendable {
    var status: Int
    var body: Data
    var contentType: String

    init(status: Int = 200, body: Data, contentType: String = "application/json; charset=utf-8") {
        self.status = status; self.body = body; self.contentType = contentType
    }

    init(status: Int = 200, json: JSONValue) {
        self.init(status: status, body: Data(json.encodedString.utf8))
    }
}

/// Handles one request per connection (Connection: close). All parsing is blocking-free
/// accumulation across `receive` callbacks until the full request is available.
private final class LocalHTTPConnection {
    private let connection: NWConnection
    private let handler: @Sendable (LocalHTTPRequest) async -> LocalHTTPResponse
    private let onFinish: @Sendable () -> Void
    private var buffer = Data()
    private static let maxBodyBytes = 8 * 1024 * 1024

    init(connection: NWConnection,
         onFinish: @Sendable @escaping () -> Void,
         handler: @Sendable @escaping (LocalHTTPRequest) async -> LocalHTTPResponse) {
        self.connection = connection
        self.onFinish = onFinish
        self.handler = handler
        // The one reliable terminal signal: every end path cancels, this reports it once.
        var finished = false
        connection.stateUpdateHandler = { state in
            if case .cancelled = state, !finished {
                finished = true
                onFinish()
            }
        }
    }

    func start() {
        connection.start(queue: .main)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.buffer.append(data) }
            if let request = Self.parse(self.buffer) {
                Task {
                    let response = await self.handler(request)
                    self.send(response)
                }
                return
            }
            if self.buffer.count > Self.maxBodyBytes { self.connection.cancel(); return }
            if isComplete || error != nil { self.connection.cancel(); return }
            self.receive()
        }
    }

    private func send(_ response: LocalHTTPResponse) {
        let reason = Self.statusReason(response.status)
        var text = "HTTP/1.1 \(response.status) \(reason)\r\n"
        text += "Content-Type: \(response.contentType)\r\n"
        text += "Content-Length: \(response.body.count)\r\n"
        text += "Connection: close\r\n\r\n"
        var payload = Data(text.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }

    /// Returns a request only once headers and the full Content-Length body have arrived.
    static func parse(_ buffer: Data) -> LocalHTTPRequest? {
        guard let separatorRange = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex..<separatorRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        lines.removeFirst()
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let bodyStart = separatorRange.upperBound
        if let length = headers["content-length"].flatMap(Int.init) {
            guard buffer.count - bodyStart >= length else { return nil }
        }
        let body = buffer.subdata(in: bodyStart..<buffer.endIndex)
        return LocalHTTPRequest(method: parts[0], path: parts[1], headers: headers, body: body)
    }

    private static func statusReason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 503: "Service Unavailable"
        default: "OK"
        }
    }
}
