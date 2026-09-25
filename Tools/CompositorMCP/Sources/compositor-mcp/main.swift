import Foundation
import CompositorMCPCore

let arguments = CommandLine.arguments
let command = arguments.count > 1 ? arguments[1] : "mcp"

func stdoutWrite(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}

func makeClient() -> CompositorClient {
    CompositorClient()
}

do {
    switch command {
    case "mcp":
        await runMCP()
    case "health":
        let status = try await makeClient().health()
        stdoutWrite(JSONRPCMessage.encode(["status": status]) + "\n")
    case "tools":
        let tools = try await makeClient().tools()
        for tool in tools {
            stdoutWrite("\(tool["name"] ?? "?") — \(tool["description"] ?? "")\n")
        }
    case "state":
        let state = try await makeClient().state()
        let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
        stdoutWrite(String(data: data, encoding: .utf8) ?? "{}")
        stdoutWrite("\n")
    case "call":
        guard arguments.count >= 3 else {
            FileHandle.standardError.write(Data("usage: compositor-mcp call <tool> [json-arguments]\n".utf8))
            exit(2)
        }
        let name = arguments[2]
        var toolArguments: [String: Any] = [:]
        if arguments.count >= 4,
           let data = arguments[3].data(using: .utf8),
           let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            toolArguments = parsed
        }
        let result = try await makeClient().call(name: name, arguments: toolArguments)
        stdoutWrite(result.message + "\n")
        exit(result.success ? 0 : 1)
    case "-h", "--help", "help":
        stdoutWrite("""
        compositor-mcp — control a running Compositor instance

        usage:
          compositor-mcp                      Run the MCP stdio server (for Codex etc.)
          compositor-mcp health               Check the control API
          compositor-mcp tools                List available tools
          compositor-mcp state                Print the canvas snapshot
          compositor-mcp call <tool> [json]   Run one tool, e.g.
                                              call draw_shape '{"kind":"Ellipse","rect":[0,0,50,50]}'

        The app is launched automatically if it isn't running.
        """)
    default:
        FileHandle.standardError.write(Data("unknown command: \(command)\n".utf8))
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

/// Runs the MCP server over newline-delimited JSON-RPC on stdin/stdout.
func runMCP() async {
    let server = MCPServer(api: makeClient())
    for await line in stdinLines() {
        let trimmed = line.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { continue }
        if let response = await server.handle(line: trimmed) {
            stdoutWrite(response + "\n")
        }
    }
}

/// Lines from standard input, delivered without dropping the connection to the running server.
func stdinLines() -> AsyncStream<String> {
    AsyncStream { continuation in
        let stdin = FileHandle.standardInput
        var buffer = Data()
        stdin.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0a) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                if let line = String(data: lineData, encoding: .utf8) {
                    continuation.yield(line)
                }
            }
        }
    }
}
