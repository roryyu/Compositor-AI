import Foundation
import Testing

@testable import Compositor

// MARK: - Local control server (HTTP bridge)

@Suite(.serialized)
@MainActor
struct LocalControlServerTests {
    private func get(_ path: String, port: Int, token: String? = nil) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func postCall(port: Int, token: String, body: Data) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/call")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    @Test func healthToolsAndTokenGuard() async throws {
        let workspace = ProjectWorkspace()
        let server = LocalControlServer(workspace: workspace)
        try await server.start()
        defer { server.stop() }
        let port = server.port

        // No token: rejected.
        let unauthenticated = try await get("/v1/health", port: port)
        #expect(unauthenticated.1 == 401)

        let (healthData, healthStatus) = try await get("/v1/health", port: port, token: server.token)
        #expect(healthStatus == 200)
        let health = try #require(try JSONDecoder().decode([String: String].self, from: healthData))
        #expect(health["status"] == "ok")

        let (toolsData, toolsStatus) = try await get("/v1/tools", port: port, token: server.token)
        #expect(toolsStatus == 200)
        let tools = try #require(try JSONDecoder().decode([ToolSummary].self, from: toolsData))
        #expect(tools.contains { $0.name == "get_canvas_state" })
        #expect(tools.contains { $0.name == "draw_shape" })
    }

    @Test func callRunsToolAgainstCurrentSession() async throws {
        let workspace = ProjectWorkspace()
        workspace.current.session.createDocument(width: 600, height: 400)
        let server = LocalControlServer(workspace: workspace)
        try await server.start()
        defer { server.stop() }

        let payload = Data(#"{"name":"add_blank_layer","arguments":{"name":"Bridge Layer"}}"#.utf8)
        let (data, status) = try await postCall(port: server.port, token: server.token, body: payload)
        #expect(status == 200)
        let result = try #require(try JSONDecoder().decode([String: AnyJSON].self, from: data))
        #expect(result["success"]?.value as? Bool == true)

        let session = workspace.current.session
        #expect(session.document?.layers.count == 1)
        #expect(session.document?.layers.first?.name == "Bridge Layer")
        // The server must leave the session in its non-busy baseline.
        #expect(session.isProjectBusy == false)

        // Undo through the bridge as well.
        let undoPayload = Data(#"{"name":"undo","arguments":{}}"#.utf8)
        let (undoData, _) = try await postCall(port: server.port, token: server.token, body: undoPayload)
        let undoResult = try #require(try JSONDecoder().decode([String: AnyJSON].self, from: undoData))
        #expect(undoResult["success"]?.value as? Bool == true)
        #expect(session.document?.layers.isEmpty == true)
    }

    @Test func callWithoutNameIsRejected() async throws {
        let workspace = ProjectWorkspace()
        let server = LocalControlServer(workspace: workspace)
        try await server.start()
        defer { server.stop() }

        let (data, status) = try await postCall(port: server.port, token: server.token,
                                                body: Data("{}".utf8))
        #expect(status == 400)
        #expect(String(data: data, encoding: .utf8)?.contains("name") == true)
    }
}

/// Minimal name/description view of an advertised tool.
private struct ToolSummary: Decodable {
    let name: String
    let description: String
}

/// Decodes arbitrary JSON values for assertions (used where JSONValue would be circular to name in tests).
private struct AnyJSON: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = NSNull() }
        else if let bool = try? container.decode(Bool.self) { value = bool }
        else if let int = try? container.decode(Int.self) { value = int }
        else if let text = try? container.decode(String.self) { value = text }
        else { value = NSNull() }
    }
}
