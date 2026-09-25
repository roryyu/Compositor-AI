import Foundation
import Testing
@testable import CompositorMCPCore

// MARK: - Endpoint store

struct EndpointStoreTests {
    @Test func loadsFromFirstReadableFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("compositor-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("control.json")
        let endpoint = Endpoint(scheme: "http", host: "127.0.0.1", port: 47831, token: "secret-token")
        try JSONEncoder().encode(endpoint).write(to: file)

        let loaded = EndpointStore.load(paths: [
            directory.appendingPathComponent("missing.json").path,
            file.path,
        ])
        #expect(loaded == endpoint)
    }

    @Test func badAndMissingFilesYieldNil() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("compositor-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bad = directory.appendingPathComponent("control.json")
        try Data("not json".utf8).write(to: bad)

        #expect(EndpointStore.load(paths: [bad.path]) == nil)
        #expect(EndpointStore.load(paths: [directory.appendingPathComponent("nope.json").path]) == nil)
    }
}

// MARK: - JSON-RPC

struct JSONRPCMessageTests {
    @Test func parsesValidRequest() throws {
        let message = JSONRPCMessage.parse(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#)
        #expect(message?["id"] as? Int == 7)
        #expect(message?["method"] as? String == "ping")
    }

    @Test func rejectsWrongVersionOrGarbage() {
        #expect(JSONRPCMessage.parse(#"{"jsonrpc":"1.0","id":1}"#) == nil)
        #expect(JSONRPCMessage.parse("garbage") == nil)
    }

    @Test func responseRoundTrips() throws {
        let line = JSONRPCMessage.response(id: "abc", result: ["ok": true])
        let parsed = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        #expect(parsed?["id"] as? String == "abc")
        let result = parsed?["result"] as? [String: Any]
        #expect(result?["ok"] as? Bool == true)
    }
}

// MARK: - MCP server

actor MockAPI: CompositorAPI {
    var toolList: [[String: Any]]
    var callOutcome: (success: Bool, message: String)
    private(set) var calls: [(name: String, arguments: [String: Any]?)] = []

    init(tools: [[String: Any]] = [], callOutcome: (Bool, String) = (true, "ok")) {
        self.toolList = tools
        self.callOutcome = callOutcome
    }

    func health() -> [String: Any] { [:] }
    func tools() -> [[String: Any]] { toolList }
    func state() -> Any { NSDictionary() }
    func call(name: String, arguments: [String: Any]?) -> (success: Bool, message: String) {
        calls.append((name, arguments))
        return callOutcome
    }
}

struct MCPServerTests {
    private func decode(_ line: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    @Test func initializeEchoesSupportedVersion() async throws {
        let server = MCPServer(api: MockAPI())
        let line = await server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        let result = try #require((try decode(line!))["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        let info = result["serverInfo"] as? [String: Any]
        #expect(info?["name"] as? String == "compositor")
    }

    @Test func initializeFallsBackForUnknownVersion() async throws {
        let server = MCPServer(api: MockAPI())
        let line = await server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"3000-01-01"}}"#)
        let result = try #require((try decode(line!))["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2024-11-05")
    }

    @Test func toolsListReturnsAppTools() async throws {
        let tools = [["name": "draw_shape", "description": "draw"]]
        let server = MCPServer(api: MockAPI(tools: tools))
        let line = await server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let result = try #require((try decode(line!))["result"] as? [String: Any])
        let listed = result["tools"] as? [[String: Any]]
        #expect(listed?.count == 1)
        #expect(listed?.first?["name"] as? String == "draw_shape")
    }

    @Test func toolCallSuccess() async throws {
        let mock = MockAPI(callOutcome: (true, "Drew Ellipse."))
        let server = MCPServer(api: mock)
        let line = await server.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"draw_shape","arguments":{"kind":"Ellipse"}}}"#)
        let result = try #require((try decode(line!))["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        let content = result["content"] as? [[String: Any]]
        #expect(content?.first?["text"] as? String == "Drew Ellipse.")
    }

    @Test func toolCallFailureIsErrorResult() async throws {
        let server = MCPServer(api: MockAPI(callOutcome: (false, "no document")))
        let line = await server.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"finish"}}"#)
        let result = try #require((try decode(line!))["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
    }

    @Test func unknownMethodAndNotifications() async throws {
        let server = MCPServer(api: MockAPI())
        let unknown = await server.handle(line: #"{"jsonrpc":"2.0","id":9,"method":"nope"}"#)
        let decoded = try decode(unknown!)
        #expect((decoded["error"] as? [String: Any])?["code"] as? Int == -32601)

        let notification = await server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        #expect(notification == nil)
    }
}
