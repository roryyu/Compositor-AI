import Foundation

/// The MCP protocol versions this bridge negotiates, newest first.
public enum MCPVersion {
    public static let supported = ["2025-06-18", "2025-03-26", "2024-11-05"]
    public static let fallback = "2024-11-05"
    public static let serverName = "compositor"
    public static let serverVersion = "1.0.0"
}

/// Handles one JSON-RPC line and returns the response line, or nil for notifications.
public final class MCPServer: Sendable {
    private let api: CompositorAPI

    public init(api: CompositorAPI) {
        self.api = api
    }

    public func handle(line: String) async -> String? {
        guard let message = JSONRPCMessage.parse(line) else {
            return JSONRPCMessage.error(id: nil, code: -32700, message: "Parse error")
        }
        let id = message["id"]
        guard let method = message["method"] as? String else {
            return JSONRPCMessage.error(id: id, code: -32600, message: "Invalid Request")
        }
        // Notifications carry no id and get no response.
        let isNotification = message["id"] == nil && method.hasPrefix("notifications/")
        if isNotification { return nil }

        switch method {
        case "initialize":
            return initialize(id: id, params: message["params"] as? [String: Any])
        case "ping":
            return JSONRPCMessage.response(id: id, result: NSDictionary())
        case "tools/list":
            return await listTools(id: id)
        case "tools/call":
            return await callTool(id: id, params: message["params"] as? [String: Any])
        case "shutdown", "exit":
            return JSONRPCMessage.response(id: id, result: NSDictionary())
        default:
            return JSONRPCMessage.error(id: id, code: -32601, message: "Method not found")
        }
    }

    // MARK: Handlers

    private func initialize(id: Any?, params: [String: Any]?) -> String {
        let requested = params?["protocolVersion"] as? String
        let version = requested.flatMap { MCPVersion.supported.contains($0) ? $0 : nil }
            ?? MCPVersion.fallback
        let result: [String: Any] = [
            "protocolVersion": version,
            "capabilities": [
                "tools": NSDictionary(),
            ],
            "serverInfo": [
                "name": MCPVersion.serverName,
                "version": MCPVersion.serverVersion,
            ],
        ]
        return JSONRPCMessage.response(id: id, result: result)
    }

    private func listTools(id: Any?) async -> String {
        do {
            let tools = try await api.tools()
            return JSONRPCMessage.response(id: id, result: ["tools": tools])
        } catch {
            return JSONRPCMessage.error(id: id, code: -32603, message: "\(error)")
        }
    }

    private func callTool(id: Any?, params: [String: Any]?) async -> String {
        guard let name = params?["name"] as? String, !name.isEmpty else {
            return JSONRPCMessage.error(id: id, code: -32602, message: "A tool name is required")
        }
        let arguments = params?["arguments"] as? [String: Any]
        do {
            let observation = try await api.call(name: name, arguments: arguments)
            return JSONRPCMessage.response(id: id, result: [
                "content": [
                    ["type": "text", "text": observation.message],
                ],
                "isError": !observation.success,
            ])
        } catch {
            // Per MCP, execution errors come back as tool results rather than JSON-RPC errors.
            return JSONRPCMessage.response(id: id, result: [
                "content": [
                    ["type": "text", "text": "\(error)"],
                ],
                "isError": true,
            ])
        }
    }
}
